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

max_users = 10000

local function get_random_user_id()
  return math.random(1, max_users)
end

local function get_random_product()
  return products[math.random(#products)]
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
  -- print(body)
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
  -- print(body)
  return wrk.format(method, path, headers, body)
end

request = function()

  local home_ratio = 0.1
  local set_currency_ratio = 0.1
  local browse_product_ratio = 0.5
  local add_to_cart_ratio = 0.1
  local view_cart_ratio = 0.15
  local checkout_ratio = 0.05

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
  else 
    return checkout()
  end

    -- return home()
    -- return browse_product()
    -- return view_cart()
    -- return checkout()
    -- return set_currency() -- concurrency bug
    -- return add_to_cart()
end