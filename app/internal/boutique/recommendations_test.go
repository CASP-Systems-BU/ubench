package boutique

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/atlas/slowpoke/pkg/llm"
)

// fakeInvoker records every downstream call and returns canned responses by
// JSON round-trip into out, so the agent is exercised fully offline.
type fakeInvoker struct {
	mu      sync.Mutex
	calls   []fakeCall
	catalog []Product
}

type fakeCall struct {
	app, method string
	payload     string
}

func (f *fakeInvoker) Invoke(ctx context.Context, app, method string, in, out any) error {
	b, _ := json.Marshal(in)
	f.mu.Lock()
	f.calls = append(f.calls, fakeCall{app, method, string(b)})
	f.mu.Unlock()

	var resp any
	switch method {
	case "ro_fetch_catalog":
		resp = FetchCatalogResponse{Catalog: f.catalog}
	case "ro_get_product":
		var req GetProductRequest
		_ = json.Unmarshal(b, &req)
		resp = GetProductResponse{Product: Product{Id: req.ProductId, Name: "name-" + req.ProductId}}
	case "ro_get_cart":
		resp = GetCartResponse{Cart: Cart{}}
	case "ro_get_currencies":
		resp = GetSupportedCurrenciesResponse{Currencies: []Currency{{CurrencyCode: "USD"}}}
	default:
		resp = map[string]any{}
	}
	rb, _ := json.Marshal(resp)
	if out == nil {
		return nil
	}
	return json.Unmarshal(rb, out)
}

func (f *fakeInvoker) methodSeq() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var ms []string
	for _, c := range f.calls {
		ms = append(ms, c.method)
	}
	return strings.Join(ms, ",")
}

func makeCatalog(n int) []Product {
	out := make([]Product, n)
	for i := 0; i < n; i++ {
		out[i] = Product{Id: fmt.Sprintf("p%02d", i), Name: fmt.Sprintf("Product %d", i)}
	}
	return out
}

func stubAgent(f Invoker) *Agent {
	return &Agent{Mode: "stub", Invoker: f, Seed: 42, CatalogSize: 10, MaxSteps: 3, Sample: 1.0}
}

func TestStubDeterministic(t *testing.T) {
	ctx := context.Background()
	in := RecommendInput{ProductIds: []string{"seedX"}, UserId: "u1", Query: "shoes"}

	f1 := &fakeInvoker{catalog: makeCatalog(8)}
	out1 := stubAgent(f1).Recommend(ctx, in, "")
	seq1 := f1.methodSeq()

	f2 := &fakeInvoker{catalog: makeCatalog(8)}
	out2 := stubAgent(f2).Recommend(ctx, in, "")
	seq2 := f2.methodSeq()

	if strings.Join(out1, ",") != strings.Join(out2, ",") {
		t.Fatalf("stub not deterministic: %v vs %v", out1, out2)
	}
	if seq1 != seq2 {
		t.Fatalf("stub fan-out not deterministic: %q vs %q", seq1, seq2)
	}
	if len(out1) == 0 {
		t.Fatalf("expected non-empty recommendations")
	}
	if !strings.HasPrefix(seq1, "ro_fetch_catalog") {
		t.Fatalf("stub should always fetch the catalog first, got %q", seq1)
	}
}

func TestStubVariableFanout(t *testing.T) {
	ctx := context.Background()
	patterns := map[string]bool{}
	for i := 0; i < 12; i++ {
		f := &fakeInvoker{catalog: makeCatalog(8)}
		in := RecommendInput{ProductIds: []string{fmt.Sprintf("seed-%d", i)}, UserId: fmt.Sprintf("u%d", i)}
		stubAgent(f).Recommend(ctx, in, "")
		patterns[f.methodSeq()] = true
	}
	if len(patterns) < 2 {
		t.Fatalf("expected varied fan-out across inputs, got %d distinct pattern(s): %v", len(patterns), patterns)
	}
}

func TestGetProductSerializesIdField(t *testing.T) {
	ctx := context.Background()
	f := &fakeInvoker{catalog: makeCatalog(5)}
	a := stubAgent(f)
	summary, _ := a.dispatch(ctx, llm.ToolCall{
		Function: llm.FunctionCall{Name: "get_product", Arguments: `{"id":"ABC"}`},
	})
	if !strings.Contains(summary, "ABC") {
		t.Fatalf("unexpected summary: %q", summary)
	}
	var got *fakeCall
	for i := range f.calls {
		if f.calls[i].method == "ro_get_product" {
			got = &f.calls[i]
		}
	}
	if got == nil {
		t.Fatal("get_product did not call ro_get_product")
	}
	if !strings.Contains(got.payload, `"id":"ABC"`) {
		t.Fatalf("payload should carry \"id\", got %s", got.payload)
	}
	if strings.Contains(got.payload, "product_id") {
		t.Fatalf("payload should NOT use product_id, got %s", got.payload)
	}
}

// mockLLM serves OpenAI-compatible chat completions. If toolName is set it
// always asks for that tool (to probe the step bound); otherwise it finishes.
func mockLLM(t *testing.T, toolName string, hits *int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*hits++
		var msg llm.Message
		if toolName != "" {
			msg = llm.Message{Role: "assistant", ToolCalls: []llm.ToolCall{{
				ID: "call1", Type: "function",
				Function: llm.FunctionCall{Name: toolName, Arguments: `{"catalog_size":5}`},
			}}}
		} else {
			msg = llm.Message{Role: "assistant", Content: "done"}
		}
		resp := map[string]any{"choices": []map[string]any{{"message": msg, "finish_reason": "stop"}}}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(resp)
	}))
}

func llmAgent(f Invoker, c *llm.Client) *Agent {
	return &Agent{Mode: "llm", Invoker: f, LLM: c, Seed: 42, CatalogSize: 10, MaxSteps: 3, Sample: 1.0}
}

func TestLLMLoopBounded(t *testing.T) {
	ctx := context.Background()
	hits := 0
	srv := mockLLM(t, "fetch_catalog", &hits) // never finishes -> must stop at MaxSteps
	defer srv.Close()

	f := &fakeInvoker{catalog: makeCatalog(8)}
	a := llmAgent(f, &llm.Client{BaseURL: srv.URL, Model: "test", HTTP: srv.Client()})
	out := a.Recommend(ctx, RecommendInput{ProductIds: []string{"x"}}, "")

	if hits != a.MaxSteps {
		t.Fatalf("expected exactly %d LLM calls, got %d", a.MaxSteps, hits)
	}
	if len(out) == 0 {
		t.Fatalf("expected recommendations from the fetched catalog")
	}
}

func TestLLMFinishThenDerive(t *testing.T) {
	ctx := context.Background()
	hits := 0
	srv := mockLLM(t, "", &hits) // finishes immediately, no tool calls
	defer srv.Close()

	f := &fakeInvoker{catalog: makeCatalog(8)}
	a := llmAgent(f, &llm.Client{BaseURL: srv.URL, Model: "test", HTTP: srv.Client()})
	out := a.Recommend(ctx, RecommendInput{ProductIds: []string{"x"}}, "")

	if hits != 1 {
		t.Fatalf("expected 1 LLM call, got %d", hits)
	}
	if len(out) == 0 {
		t.Fatalf("expected a derived catalog fetch + recommendations")
	}
}

func TestLLMErrorFallsBackToStub(t *testing.T) {
	ctx := context.Background()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	defer srv.Close()

	f := &fakeInvoker{catalog: makeCatalog(8)}
	a := llmAgent(f, &llm.Client{BaseURL: srv.URL, Model: "test", HTTP: srv.Client()})
	out := a.Recommend(ctx, RecommendInput{ProductIds: []string{"x"}, UserId: "u"}, "")

	if len(out) == 0 {
		t.Fatalf("expected stub fallback to still return recommendations")
	}
	// The stub path always fetches the catalog.
	if !strings.Contains(f.methodSeq(), "ro_fetch_catalog") {
		t.Fatalf("fallback should have run the stub (catalog fetch), got %q", f.methodSeq())
	}
}

func TestModeOverrideForcesStub(t *testing.T) {
	ctx := context.Background()
	hits := 0
	srv := mockLLM(t, "fetch_catalog", &hits)
	defer srv.Close()

	f := &fakeInvoker{catalog: makeCatalog(8)}
	a := llmAgent(f, &llm.Client{BaseURL: srv.URL, Model: "test", HTTP: srv.Client()})
	// Per-request override to stub must bypass the model entirely.
	_ = a.Recommend(ctx, RecommendInput{ProductIds: []string{"x"}}, "stub")
	if hits != 0 {
		t.Fatalf("stub override should not call the LLM, got %d calls", hits)
	}
}
