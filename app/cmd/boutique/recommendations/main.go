package main

import (
	"context"
	"fmt"
	"github.com/atlas/slowpoke/internal/boutique"
	"github.com/atlas/slowpoke/pkg/wrappers"
	"net"
	"net/http"
	"runtime"
)

func heartbeat(w http.ResponseWriter, r *http.Request) {
	_, err := w.Write([]byte("Heartbeat\n"))
	if err != nil {
		return
	}
}

func getRecommendations(ctx context.Context, req *boutique.GetRecommendationsRequest) *boutique.GetRecommendationsResponse {
	products := boutique.GetRecommendationsFor(ctx, *req)
	resp := boutique.GetRecommendationsResponse{ProductIds: products}
	return &resp
}

func main() {
	fmt.Println(runtime.GOMAXPROCS(8))
	boutique.InitAgent() // read AGENT_* env once, build the stub/llm backend
	http.HandleFunc("/heartbeat", heartbeat)
	http.HandleFunc("/ro_get_recommendations", wrappers.Wrapper[boutique.GetRecommendationsRequest, boutique.GetRecommendationsResponse](getRecommendations))
	fmt.Println("Server started on port 3000")
	listener, err := net.Listen("tcp", ":3000")
	if err != nil {
		panic(err)
	}
	panic(http.Serve(listener, nil))
}
