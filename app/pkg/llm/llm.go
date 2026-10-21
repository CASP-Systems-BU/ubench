// Package llm is a minimal OpenAI-compatible chat-completions client used by
// the agentic boutique services. It mirrors the style of pkg/invoke (plain
// net/http + JSON) and deliberately depends only on the standard library, so
// the one boutique image keeps building without new modules.
//
// It targets any OpenAI-compatible /chat/completions endpoint (OpenRouter,
// vLLM, Ollama, llama.cpp server, ...). The agent loop uses tool/function
// calling: it sends the available tools and reads back the model's tool_calls.
package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

// Message is one chat message. For assistant turns it may carry ToolCalls; for
// tool-result turns set Role="tool", ToolCallID and Name.
type Message struct {
	Role       string     `json:"role"`
	Content    string     `json:"content,omitempty"`
	ToolCalls  []ToolCall `json:"tool_calls,omitempty"`
	ToolCallID string     `json:"tool_call_id,omitempty"`
	Name       string     `json:"name,omitempty"`
}

// ToolCall is one function call the model asked for.
type ToolCall struct {
	ID       string       `json:"id"`
	Type     string       `json:"type"`
	Function FunctionCall `json:"function"`
}

// FunctionCall carries the called function's name and its JSON-encoded args.
type FunctionCall struct {
	Name string `json:"name"`
	// Arguments is a JSON object encoded as a string (OpenAI wire format).
	Arguments string `json:"arguments"`
}

// Tool advertises one callable function to the model.
type Tool struct {
	Type     string             `json:"type"`
	Function FunctionDefinition `json:"function"`
}

// FunctionDefinition is a tool's name + JSON-schema parameters.
type FunctionDefinition struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Parameters  json.RawMessage `json:"parameters,omitempty"`
}

type chatRequest struct {
	Model       string    `json:"model"`
	Messages    []Message `json:"messages"`
	Tools       []Tool    `json:"tools,omitempty"`
	ToolChoice  string    `json:"tool_choice,omitempty"`
	Temperature float64   `json:"temperature"`
	Seed        *int      `json:"seed,omitempty"`
}

type chatResponse struct {
	Choices []struct {
		Message      Message `json:"message"`
		FinishReason string  `json:"finish_reason"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

// Client is a configured chat-completions client. Build one with NewFromEnv and
// reuse it across requests (the underlying http.Client is safe for concurrent
// use); per-call deadlines come from the ctx passed to Chat.
type Client struct {
	BaseURL     string
	Model       string
	APIKey      string
	Temperature float64
	Seed        int
	HTTP        *http.Client
}

// Configured reports whether a usable endpoint/model are set (llm mode needs
// both; stub mode leaves them empty).
func (c *Client) Configured() bool {
	return c != nil && c.BaseURL != "" && c.Model != ""
}

// NewFromEnv builds a Client from AGENT_LLM_* / AGENT_SEED env vars. It always
// returns a non-nil Client; callers gate real use on Configured().
//
//	AGENT_LLM_BASE_URL   e.g. https://openrouter.ai/api/v1  (no trailing /chat/completions)
//	AGENT_LLM_MODEL      e.g. openai/gpt-4o-mini
//	AGENT_LLM_API_KEY    bearer token (optional for keyless in-cluster servers)
//	AGENT_LLM_TIMEOUT_MS per-request timeout fallback (default 8000)
//	AGENT_LLM_TEMPERATURE sampling temperature (default 0)
//	AGENT_SEED           request seed for reproducibility (default 0 = omit)
func NewFromEnv() *Client {
	timeout := envInt("AGENT_LLM_TIMEOUT_MS", 8000)
	return &Client{
		BaseURL:     strings.TrimSpace(os.Getenv("AGENT_LLM_BASE_URL")),
		Model:       strings.TrimSpace(os.Getenv("AGENT_LLM_MODEL")),
		APIKey:      strings.TrimSpace(os.Getenv("AGENT_LLM_API_KEY")),
		Temperature: envFloat("AGENT_LLM_TEMPERATURE", 0),
		Seed:        envInt("AGENT_SEED", 0),
		HTTP:        &http.Client{Timeout: time.Duration(timeout) * time.Millisecond},
	}
}

// Chat sends one turn and returns the assistant message (which may carry
// tool_calls). It returns an error on transport failure, non-200 status, or an
// empty/error response — callers fall back to the stub on any error.
func (c *Client) Chat(ctx context.Context, messages []Message, tools []Tool) (*Message, error) {
	body := chatRequest{
		Model:       c.Model,
		Messages:    messages,
		Tools:       tools,
		Temperature: c.Temperature,
	}
	if len(tools) > 0 {
		body.ToolChoice = "auto"
	}
	if c.Seed != 0 {
		s := c.Seed
		body.Seed = &s
	}
	buf, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	url := strings.TrimRight(c.BaseURL, "/") + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(buf))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+c.APIKey)
	}
	hc := c.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("llm: status %d: %s", resp.StatusCode, truncate(string(raw), 300))
	}
	var cr chatResponse
	if err := json.Unmarshal(raw, &cr); err != nil {
		return nil, fmt.Errorf("llm: decode: %w", err)
	}
	if cr.Error != nil {
		return nil, fmt.Errorf("llm: %s", cr.Error.Message)
	}
	if len(cr.Choices) == 0 {
		return nil, fmt.Errorf("llm: no choices")
	}
	return &cr.Choices[0].Message, nil
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
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
