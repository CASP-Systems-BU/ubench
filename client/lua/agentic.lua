-- Agentic request mix: the standard boutique traffic PLUS a `recommend` route
-- that drives the (now agentic) recommendations service through the frontend's
-- /ro_recommend passthrough. The default mix.lua is intentionally left
-- untouched so historical `request: mix` runs stay byte-identical; select this
-- mix with `request: agentic` in an experiment spec.
--
-- stub backend (AGENT_MODE=stub): recommend calls are cheap in-cluster RPC
-- fan-out, safe at full rate. llm backend (AGENT_MODE=llm): keep the experiment
-- rate low (each recommend hits the model) — see experiments/boutique-agentic-llm.yaml.
require "socket"

products = {
    '0PUK6V6EV0',
    '1YMWWN1N4O',
    '2ZYFJ3GM2N',
    '66VCHSJNUP',
    '6E92ZMYYFZ',
    '9SIQT8TOJO',
    'L9ECAV7KIM',
    'LS4PSXUNUM',
    'OLJCESPC7Z'}

queries = {
    'comfortable shoes',
    'kitchen accessories',
    'a gift for a friend',
    'home decor',
    'something vintage',
    'office supplies'}

max_users = 10000

local function get_random_user_id()
  return math.random(1, max_users)
end

local function get_random_product()
  return products[math.random(#products)]
end

local function get_random_query()
  return queries[math.random(#queries)]
end

local function home()
  local method = "POST"
  local path = "/ro_home"
  local headers = {}
  headers["content-type"]="application/json"
  local body = '{"user_id": "' .. get_random_user_id() .. '", "catalog_size": 10}'
  return wrk.format(method, path, headers, body)
end

local function set_currency()
  local method = "POST"
  local path = "/set_currency"
  local headers = {}
  headers["content-type"]="application/json"
  local body = '{"currencyCode": "EUR", "rage": "1.2345"}'
  return wrk.format(method, path, headers, body)
end

local function browse_product()
  local method = "POST"
  local path = "/ro_browse_product"
  local headers = {}
  headers["content-type"]="application/json"
  local body = '{"product_id": "' .. get_random_product() .. '"}'
  return wrk.format(method, path, headers, body)
end

local function add_to_cart()
  local method = "POST"
  local path = "/add_to_cart"
  local headers = {}
  headers["content-type"]="application/json"
  local body = '{"user_id": "' .. get_random_user_id() .. '", "product_id": "' .. get_random_product() .. '", "quantity": 1}'
  return wrk.format(method, path, headers, body)
end

local function view_cart()
  local method = "POST"
  local path = "/ro_view_cart"
  local headers = {}
  headers["content-type"]="application/json"
  local body = '{"user_id": "' .. get_random_user_id() .. '"}'
  return wrk.format(method, path, headers, body)
end

local function checkout()
  local method = "POST"
  local path = "/checkout"
  local headers = {}
  headers["content-type"]="application/json"
  local addr = '{"street_address": "1234 Main St", "city": "Mountain View", "state": "CA", "zip_code": 94043, "country": "US"}'
  local email = 'someone@example.com'
  local credit_card = '{"card_number": "4432-8015-6152-0454", "card_type": "visa", "expiration_month": 1, "expiration_year": 2039}'
  local body = '{"user_id": "' .. get_random_user_id() .. '", "address": ' .. addr .. ', "user_currency": "EUR", "email": "' .. email .. '", "credit_card": ' .. credit_card .. '}'
  return wrk.format(method, path, headers, body)
end

-- Agentic route: ask the recommendations agent for suggestions. The body shape
-- is boutique.GetRecommendationsRequest; mode is left empty so the deployment's
-- AGENT_MODE env decides stub vs llm.
local function recommend()
  local method = "POST"
  local path = "/ro_recommend"
  local headers = {}
  headers["content-type"]="application/json"
  local seed = '"' .. get_random_product() .. '", "' .. get_random_product() .. '"'
  local body = '{"product_ids": [' .. seed .. '], "user_id": "' .. get_random_user_id() .. '", "query": "' .. get_random_query() .. '"}'
  return wrk.format(method, path, headers, body)
end

request = function()

  local home_ratio = 0.1
  local set_currency_ratio = 0.05
  local browse_product_ratio = 0.4
  local add_to_cart_ratio = 0.1
  local view_cart_ratio = 0.1
  local recommend_ratio = 0.2
  -- checkout gets the remaining 0.05

  local coin = math.random()
  if coin < home_ratio then
    return home()
  elseif coin < home_ratio + set_currency_ratio then
    return set_currency()
  elseif coin < home_ratio + set_currency_ratio + browse_product_ratio then
    return browse_product()
  elseif coin < home_ratio + set_currency_ratio + browse_product_ratio + add_to_cart_ratio then
    return add_to_cart()
  elseif coin < home_ratio + set_currency_ratio + browse_product_ratio + add_to_cart_ratio + view_cart_ratio then
    return view_cart()
  elseif coin < home_ratio + set_currency_ratio + browse_product_ratio + add_to_cart_ratio + view_cart_ratio + recommend_ratio then
    return recommend()
  else
    return checkout()
  end
end
