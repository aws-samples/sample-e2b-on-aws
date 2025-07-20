package auth

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/service/ecr"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

// AWSAuthResponse represents the authentication response from AWS ECR
type AWSAuthResponse struct {
	Token         string
	ExpiresAt     time.Time
	ProxyEndpoint string
}

// GetAWSECRAuthToken retrieves an authentication token for AWS ECR
func GetAWSECRAuthToken() (*AWSAuthResponse, error) {
	// Get AWS session
	sess, err := consts.GetAWSSession()
	if err != nil {
		return nil, fmt.Errorf("failed to get AWS session: %v", err)
	}

	// Create ECR client
	ecrClient := ecr.New(sess)

	// Get authorization token
	input := &ecr.GetAuthorizationTokenInput{}
	result, err := ecrClient.GetAuthorizationToken(input)
	if err != nil {
		return nil, fmt.Errorf("failed to get ECR authorization token: %v", err)
	}

	if len(result.AuthorizationData) == 0 {
		return nil, fmt.Errorf("no authorization data returned from ECR")
	}

	authData := result.AuthorizationData[0]
	
	return &AWSAuthResponse{
		Token:         *authData.AuthorizationToken,
		ExpiresAt:     *authData.ExpiresAt,
		ProxyEndpoint: *authData.ProxyEndpoint,
	}, nil
}

// HandleAWSECRToken handles the token request for AWS ECR
func HandleAWSECRToken(w http.ResponseWriter, req *http.Request) (string, error) {
	authResponse, err := GetAWSECRAuthToken()
	if err != nil {
		log.Printf("Error getting AWS ECR auth token: %v", err)
		http.Error(w, "Failed to get ECR authorization token", http.StatusInternalServerError)
		return "", err
	}

	// Decode the base64 token which is in the format "username:password"
	decodedToken, err := base64.StdEncoding.DecodeString(authResponse.Token)
	if err != nil {
		log.Printf("Error decoding AWS ECR auth token: %v", err)
		http.Error(w, "Failed to decode ECR authorization token", http.StatusInternalServerError)
		return "", err
	}

	// The token is in the format "AWS:password"
	// We only need the password part which is the actual token
	tokenParts := strings.SplitN(string(decodedToken), ":", 2)
	if len(tokenParts) != 2 {
		log.Printf("Invalid AWS ECR auth token format")
		http.Error(w, "Invalid ECR authorization token format", http.StatusInternalServerError)
		return "", fmt.Errorf("invalid ECR token format")
	}

	// Return the actual token
	token := tokenParts[1]

	// Create a response similar to Docker Registry v2 token response
	tokenResponse := map[string]interface{}{
		"token":      token,
		"expires_in": int(time.Until(authResponse.ExpiresAt).Seconds()),
		"issued_at":  time.Now().Format(time.RFC3339),
	}

	responseJSON, err := json.Marshal(tokenResponse)
	if err != nil {
		log.Printf("Error marshaling token response: %v", err)
		http.Error(w, "Failed to create token response", http.StatusInternalServerError)
		return "", err
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write(responseJSON)

	return token, nil
}
