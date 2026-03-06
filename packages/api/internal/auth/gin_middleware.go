package auth

import (
	"context"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"

	"github.com/e2b-dev/infra/packages/api/internal/api"
	authcache "github.com/e2b-dev/infra/packages/api/internal/cache/auth"
)

// CreateGinAPIKeyMiddleware returns a Gin middleware that validates
// API keys (e2b_...) from the X-API-Key header.
// This is used for v2 routes that are registered outside the OpenAPI validator.
func CreateGinAPIKeyMiddleware(
	teamValidationFunction func(context.Context, string) (authcache.AuthTeamInfo, *api.APIError),
) gin.HandlerFunc {
	return func(c *gin.Context) {
		apiKey := strings.TrimSpace(c.GetHeader("X-API-Key"))
		if apiKey == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized, api.Error{
				Code:    http.StatusUnauthorized,
				Message: "X-API-Key header is missing",
			})
			return
		}

		if !strings.HasPrefix(apiKey, "e2b_") {
			c.AbortWithStatusJSON(http.StatusUnauthorized, api.Error{
				Code:    http.StatusUnauthorized,
				Message: "Invalid API key format",
			})
			return
		}

		teamInfo, apiErr := teamValidationFunction(c.Request.Context(), apiKey)
		if apiErr != nil {
			c.AbortWithStatusJSON(apiErr.Code, api.Error{
				Code:    int32(apiErr.Code),
				Message: apiErr.ClientMsg,
			})
			return
		}

		c.Set(TeamContextKey, teamInfo)
		c.Next()
	}
}
