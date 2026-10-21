package boutique

import (
	"context"
)

// contains reports whether e is in s. Shared with agent.go (same package).
func contains(s []string, e string) bool {
	for _, a := range s {
		if a == e {
			return true
		}
	}
	return false
}

// GetRecommendations returns recommended product IDs for the given seed
// products using the configured agent backend (stub by default). Kept as the
// plain product-id entry point for backward compatibility.
func GetRecommendations(ctx context.Context, productIds []string) []string {
	return agentFor().Recommend(ctx, RecommendInput{ProductIds: productIds}, "")
}

// GetRecommendationsFor runs the agent with the full request, honoring the
// optional per-request Mode override and user context (user id / query).
func GetRecommendationsFor(ctx context.Context, req GetRecommendationsRequest) []string {
	return agentFor().Recommend(ctx, RecommendInput{
		ProductIds: req.ProductIds,
		UserId:     req.UserId,
		Query:      req.Query,
	}, req.Mode)
}
