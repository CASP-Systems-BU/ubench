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

func home(ctx context.Context, req *boutique.HomeRequest) *boutique.HomeResponse {
	// slowpoke.SlowpokeCheck("home")
	resp := boutique.Home(ctx, *req)
	return &resp
}

func setCurrency(ctx context.Context, req *boutique.FrontendSetCurrencyRequest) *boutique.FrontendSetCurrencyResponse {
	// slowpoke.SlowpokeCheck("setCurrency")
	boutique.FrontendSetCurrency(ctx, req.Cur)
	resp := boutique.FrontendSetCurrencyResponse{OK: "OK"}
	return &resp
}

func browseProduct(ctx context.Context, req *boutique.BrowseProductRequest) *boutique.BrowseProductResponse {
	// slowpoke.SlowpokeCheck("browseProduct")
	resp := boutique.BrowseProduct(ctx, req.ProductId)
	return &resp
}

func addToCart(ctx context.Context, request *boutique.AddToCartRequest) *boutique.AddToCartResponse {
	// slowpoke.SlowpokeCheck("addToCart")
	resp := boutique.AddToCart(ctx, *request)
	return &resp
}

func viewCart(ctx context.Context, request *boutique.ViewCartRequest) *boutique.ViewCartResponse {
	// slowpoke.SlowpokeCheck("viewCart")
	resp := boutique.ViewCart(ctx, *request)
	return &resp
}

func checkout(ctx context.Context, request *boutique.CheckoutRequest) *boutique.CheckoutResponse {
	// slowpoke.SlowpokeCheck("checkout")
	resp := boutique.Checkout(ctx, *request)
	return &resp
}

func recommend(ctx context.Context, request *boutique.GetRecommendationsRequest) *boutique.GetRecommendationsResponse {
	resp := boutique.Recommend(ctx, *request)
	return &resp
}

func main() {
	fmt.Println(runtime.GOMAXPROCS(8))
	http.HandleFunc("/heartbeat", heartbeat)
	http.HandleFunc("/ro_home", wrappers.Wrapper[boutique.HomeRequest, boutique.HomeResponse](home))
	http.HandleFunc("/set_currency", wrappers.Wrapper[boutique.FrontendSetCurrencyRequest, boutique.FrontendSetCurrencyResponse](setCurrency))
	http.HandleFunc("/ro_browse_product", wrappers.Wrapper[boutique.BrowseProductRequest, boutique.BrowseProductResponse](browseProduct))
	http.HandleFunc("/add_to_cart", wrappers.Wrapper[boutique.AddToCartRequest, boutique.AddToCartResponse](addToCart))
	http.HandleFunc("/ro_view_cart", wrappers.Wrapper[boutique.ViewCartRequest, boutique.ViewCartResponse](viewCart))
	http.HandleFunc("/checkout", wrappers.Wrapper[boutique.CheckoutRequest, boutique.CheckoutResponse](checkout))
	http.HandleFunc("/ro_recommend", wrappers.Wrapper[boutique.GetRecommendationsRequest, boutique.GetRecommendationsResponse](recommend))
	fmt.Println("Server started on :3000")
	listener, err := net.Listen("tcp", ":3000")
	if err != nil {
		panic(err)
	}
	panic(http.Serve(listener, nil))
}
