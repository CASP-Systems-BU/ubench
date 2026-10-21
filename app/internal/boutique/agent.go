package boutique

// Agentic recommendations.
//
// The recommendations service used to be a fixed, single-call stub (and was in
// fact never wired into the request path). Here it becomes a bounded
// tool-calling agent: its "tools" are the existing boutique services, invoked
// over the same k8s-DNS HTTP/JSON contract as pkg/invoke, so in llm mode the
// downstream fan-out is decided by the model and varies with the input. A
// deterministic stub backend reproduces agent-shaped (variable) fan-out for
// free at full request rate, for CI and dense telemetry; the openai backend
// adds real external egress. Any backend error falls back to the stub so a
// request never fails.
//
// Mode and limits come from env (read once by InitAgent):
//
//	AGENT_MODE          stub (default) | llm
//	AGENT_MAX_STEPS     max tool-call rounds in llm mode (default 3)
//	AGENT_SAMPLE        fraction of llm-mode calls that hit the model (default 1.0;
//	                    the rest use the stub — bounds real-API cost at load)
//	AGENT_SEED          stub RNG seed base (default 42)
//	AGENT_CATALOG_SIZE  catalog_size sent to productcatalog (default 10)
//
// plus AGENT_LLM_* (see pkg/llm) for the openai backend.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"math/rand"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/atlas/slowpoke/pkg/llm"
)

// Invoker performs one downstream service call (JSON in, JSON out). It mirrors
// pkg/invoke's URL/JSON contract but returns errors instead of panicking and
// honors the ctx deadline, so a failed tool call degrades gracefully instead of
// crashing the request. A fake Invoker makes the agent unit-testable offline.
type Invoker interface {
	Invoke(ctx context.Context, app, method string, in, out any) error
}

type httpInvoker struct{ client *http.Client }

func (h httpInvoker) Invoke(ctx context.Context, app, method string, in, out any) error {
	buf, err := json.Marshal(in)
	if err != nil {
		return err
	}
	// Same address scheme as pkg/invoke.Invoke.
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local:%s/%s", app, "default", "80", method)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBuffer(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("invoke %s/%s: status %d: %s", app, method, resp.StatusCode, string(b))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// RecommendInput is the agent's request: seed products plus optional user
// context that enriches the prompt and enables the get_cart tool.
type RecommendInput struct {
	ProductIds []string
	UserId     string
	Query      string
}

// Agent holds the configured backend and limits. It is built once and shared
// across requests; it keeps no mutable state (per-request randomness is derived
// from the input), so it is safe for concurrent use.
type Agent struct {
	Mode        string // "stub" | "llm"
	Invoker     Invoker
	LLM         *llm.Client
	MaxSteps    int
	Sample      float64
	Seed        int64
	CatalogSize int
}

var (
	sharedAgent *Agent
	agentOnce   sync.Once
)

// InitAgent builds the shared agent from env. Call once at service startup.
func InitAgent() {
	agentOnce.Do(func() { sharedAgent = NewAgentFromEnv() })
}

// NewAgentFromEnv constructs an Agent from AGENT_* env vars with a real HTTP
// invoker. Exposed for completeness; InitAgent is the normal entry point.
func NewAgentFromEnv() *Agent {
	mode := strings.ToLower(strings.TrimSpace(os.Getenv("AGENT_MODE")))
	if mode != "llm" {
		mode = "stub"
	}
	return &Agent{
		Mode:        mode,
		Invoker:     httpInvoker{client: &http.Client{Timeout: 10 * time.Second}},
		LLM:         llm.NewFromEnv(),
		MaxSteps:    envInt("AGENT_MAX_STEPS", 3),
		Sample:      envFloat("AGENT_SAMPLE", 1.0),
		Seed:        int64(envInt("AGENT_SEED", 42)),
		CatalogSize: envInt("AGENT_CATALOG_SIZE", 10),
	}
}

func agentFor() *Agent {
	InitAgent()
	return sharedAgent
}

// Recommend runs the agent for one request and returns recommended product IDs.
// It selects llm vs stub by configured mode, per-request sampling, and a
// per-request mode override; llm failures fall back to the stub.
func (a *Agent) Recommend(ctx context.Context, in RecommendInput, modeOverride string) []string {
	mode := a.Mode
	switch strings.ToLower(strings.TrimSpace(modeOverride)) {
	case "llm":
		mode = "llm"
	case "stub":
		mode = "stub"
	}
	h := a.hash(in)
	if mode == "llm" && a.LLM.Configured() && a.sampled(h) {
		if ids, err := a.runLLM(ctx, in); err == nil && len(ids) > 0 {
			return ids
		}
		// fall through to the stub on any error / empty result
	}
	return a.runStub(ctx, in, h)
}

// runStub issues a deterministic-but-input-dependent sequence of real tool calls
// (so stub runs still exercise variable fan-out), then samples recommendations
// from the catalog. Pure function of (input, seed): same input -> same calls and
// same result; different inputs -> different fan-out.
func (a *Agent) runStub(ctx context.Context, in RecommendInput, h uint64) []string {
	rng := rand.New(rand.NewSource(int64(h) ^ a.Seed))

	var cat FetchCatalogResponse
	if err := a.Invoker.Invoke(ctx, "productcatalog", "ro_fetch_catalog",
		FetchCatalogRequest{CatalogSize: a.catalogSize()}, &cat); err != nil {
		return nil
	}
	ids := productIDs(cat.Catalog)

	// Variable extra fan-out: 0-2 product look-ups, maybe the cart, maybe currencies.
	probes := rng.Intn(3)
	for i := 0; i < probes && len(ids) > 0; i++ {
		var gp GetProductResponse
		_ = a.Invoker.Invoke(ctx, "productcatalog", "ro_get_product",
			GetProductRequest{ProductId: ids[rng.Intn(len(ids))]}, &gp)
	}
	if in.UserId != "" && rng.Intn(2) == 0 {
		var gc GetCartResponse
		_ = a.Invoker.Invoke(ctx, "cart", "ro_get_cart", GetCartRequest{UserId: in.UserId}, &gc)
	}
	if rng.Intn(4) == 0 {
		var cur GetSupportedCurrenciesResponse
		_ = a.Invoker.Invoke(ctx, "currency", "ro_get_currencies", GetSupportedCurrenciesRequest{}, &cur)
	}

	return sampleIDs(rng, filterOut(ids, in.ProductIds), 5)
}

// runLLM lets the model drive the tool calls (the real, variable fan-out we want
// to observe), executing each against the live services, then derives the final
// recommendation list from the catalog it saw (robust to the model not emitting
// exact product IDs). Bounded by MaxSteps; errors propagate so Recommend can
// fall back to the stub.
func (a *Agent) runLLM(ctx context.Context, in RecommendInput) ([]string, error) {
	msgs := []llm.Message{
		{Role: "system", Content: agentSystemPrompt},
		{Role: "user", Content: userPrompt(in)},
	}
	var lastCatalog []Product
	for step := 0; step < a.MaxSteps; step++ {
		msg, err := a.LLM.Chat(ctx, msgs, agentTools)
		if err != nil {
			return nil, err
		}
		msgs = append(msgs, *msg)
		if len(msg.ToolCalls) == 0 {
			break // model produced a final answer
		}
		for _, tc := range msg.ToolCalls {
			summary, products := a.dispatch(ctx, tc)
			if products != nil {
				lastCatalog = products
			}
			msgs = append(msgs, llm.Message{
				Role:       "tool",
				ToolCallID: tc.ID,
				Name:       tc.Function.Name,
				Content:    summary,
			})
		}
	}
	if lastCatalog == nil {
		// Model never fetched a catalog; fetch one so we can still answer.
		var cat FetchCatalogResponse
		if err := a.Invoker.Invoke(ctx, "productcatalog", "ro_fetch_catalog",
			FetchCatalogRequest{CatalogSize: a.catalogSize()}, &cat); err != nil {
			return nil, err
		}
		lastCatalog = cat.Catalog
	}
	rng := rand.New(rand.NewSource(int64(a.hash(in))))
	return sampleIDs(rng, filterOut(productIDs(lastCatalog), in.ProductIds), 5), nil
}

// dispatch executes one model-requested tool against the real services and
// returns a short textual summary for the model (plus the catalog when fetched).
func (a *Agent) dispatch(ctx context.Context, tc llm.ToolCall) (string, []Product) {
	var args map[string]any
	if s := strings.TrimSpace(tc.Function.Arguments); s != "" {
		_ = json.Unmarshal([]byte(s), &args)
	}
	getStr := func(k string) string {
		if v, ok := args[k]; ok {
			if s, ok := v.(string); ok {
				return s
			}
		}
		return ""
	}
	switch tc.Function.Name {
	case "fetch_catalog":
		size := a.catalogSize()
		if v, ok := args["catalog_size"]; ok {
			if f, ok := v.(float64); ok && int(f) > 0 {
				size = int(f)
			}
		}
		var cat FetchCatalogResponse
		if err := a.Invoker.Invoke(ctx, "productcatalog", "ro_fetch_catalog",
			FetchCatalogRequest{CatalogSize: size}, &cat); err != nil {
			return "error: " + err.Error(), nil
		}
		return fmt.Sprintf("catalog has %d products: %s",
			len(cat.Catalog), strings.Join(productIDs(cat.Catalog), ", ")), cat.Catalog
	case "get_product":
		// NB: GetProductRequest.ProductId serializes as "id", not "product_id".
		var gp GetProductResponse
		if err := a.Invoker.Invoke(ctx, "productcatalog", "ro_get_product",
			GetProductRequest{ProductId: getStr("id")}, &gp); err != nil {
			return "error: " + err.Error(), nil
		}
		return fmt.Sprintf("product %s: %s", gp.Product.Id, gp.Product.Name), nil
	case "get_cart":
		uid := getStr("user_id")
		var gc GetCartResponse
		if err := a.Invoker.Invoke(ctx, "cart", "ro_get_cart",
			GetCartRequest{UserId: uid}, &gc); err != nil {
			return "error: " + err.Error(), nil
		}
		return fmt.Sprintf("cart for %s has %d items", uid, len(gc.Cart.Items)), nil
	case "list_currencies":
		var cur GetSupportedCurrenciesResponse
		if err := a.Invoker.Invoke(ctx, "currency", "ro_get_currencies",
			GetSupportedCurrenciesRequest{}, &cur); err != nil {
			return "error: " + err.Error(), nil
		}
		return fmt.Sprintf("%d currencies supported", len(cur.Currencies)), nil
	default:
		return "unknown tool: " + tc.Function.Name, nil
	}
}

func (a *Agent) catalogSize() int {
	if a.CatalogSize > 0 {
		return a.CatalogSize
	}
	return 10
}

// sampled maps the input hash to a stable [0,1) draw and compares to Sample, so
// the decision to call the model is deterministic per input.
func (a *Agent) sampled(h uint64) bool {
	if a.Sample >= 1.0 {
		return true
	}
	if a.Sample <= 0 {
		return false
	}
	return float64(h%10000)/10000.0 < a.Sample
}

func (a *Agent) hash(in RecommendInput) uint64 {
	ids := append([]string(nil), in.ProductIds...)
	sort.Strings(ids)
	h := fnv.New64a()
	_, _ = io.WriteString(h, strings.Join(ids, ","))
	_, _ = io.WriteString(h, "|"+in.UserId+"|"+in.Query)
	return h.Sum64()
}

// --- tool schemas + prompt ---------------------------------------------------

var agentTools = []llm.Tool{
	{Type: "function", Function: llm.FunctionDefinition{
		Name:        "fetch_catalog",
		Description: "List products in the store catalog.",
		Parameters: json.RawMessage(`{"type":"object","properties":` +
			`{"catalog_size":{"type":"integer","description":"max products to return"}}}`),
	}},
	{Type: "function", Function: llm.FunctionDefinition{
		Name:        "get_product",
		Description: "Get details for one product by id.",
		Parameters: json.RawMessage(`{"type":"object","properties":` +
			`{"id":{"type":"string"}},"required":["id"]}`),
	}},
	{Type: "function", Function: llm.FunctionDefinition{
		Name:        "get_cart",
		Description: "Get the current cart for a user id.",
		Parameters: json.RawMessage(`{"type":"object","properties":` +
			`{"user_id":{"type":"string"}},"required":["user_id"]}`),
	}},
	{Type: "function", Function: llm.FunctionDefinition{
		Name:        "list_currencies",
		Description: "List supported currencies.",
		Parameters:  json.RawMessage(`{"type":"object","properties":{}}`),
	}},
}

const agentSystemPrompt = "You are the recommendations service for an online store. " +
	"Use the tools to inspect the catalog (and the user's cart if helpful), then " +
	"recommend a few relevant products. Call tools as needed, then reply briefly."

func userPrompt(in RecommendInput) string {
	var b strings.Builder
	b.WriteString("Recommend products.")
	if in.Query != "" {
		b.WriteString(" User interest: " + in.Query + ".")
	}
	if len(in.ProductIds) > 0 {
		b.WriteString(" Seed products: " + strings.Join(in.ProductIds, ", ") + ".")
	}
	if in.UserId != "" {
		b.WriteString(" User id: " + in.UserId + ".")
	}
	return b.String()
}

// --- helpers -----------------------------------------------------------------

func productIDs(products []Product) []string {
	out := make([]string, 0, len(products))
	for _, p := range products {
		out = append(out, p.Id)
	}
	return out
}

func filterOut(ids, remove []string) []string {
	out := make([]string, 0, len(ids))
	for _, id := range ids {
		if !contains(remove, id) {
			out = append(out, id)
		}
	}
	return out
}

// sampleIDs returns up to n ids chosen without replacement using rng.
func sampleIDs(rng *rand.Rand, ids []string, n int) []string {
	if n > len(ids) {
		n = len(ids)
	}
	if n <= 0 {
		return []string{}
	}
	perm := rng.Perm(len(ids))[:n]
	out := make([]string, n)
	for i, idx := range perm {
		out[i] = ids[idx]
	}
	return out
}

func envInt(key string, def int) int {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envFloat(key string, def float64) float64 {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}
