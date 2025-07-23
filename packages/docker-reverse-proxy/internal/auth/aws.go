package auth

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ecr"
	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/constants"
)

// AWSAuthResponse represents the authentication response from AWS ECR
type AWSAuthResponse struct {
	Token         string
	ExpiresAt     time.Time
	ProxyEndpoint string
}

// EnsureECRRepositoryExists checks if the ECR repository exists and creates it if it doesn't
func EnsureECRRepositoryExists(templateID string) error {
	// Get AWS session
	sess, err := constants.GetAWSSession()
	if err != nil {
		return fmt.Errorf("failed to get AWS session: %v", err)
	}
	
	// Create ECR client
	ecrClient := ecr.New(sess)
	
	// Format repository name for the template using base_repo_name/template_id format
	templateRepo := fmt.Sprintf("%s/%s", constants.AWSECRRepository, templateID)
	
	log.Printf("[DEBUG] ECR - Checking if repository %s exists", templateRepo)
	
	// Check if repository exists
	_, err = ecrClient.DescribeRepositories(&ecr.DescribeRepositoriesInput{
		RepositoryNames: []*string{aws.String(templateRepo)},
	})
	
	if err != nil {
		if aerr, ok := err.(awserr.Error); ok && aerr.Code() == ecr.ErrCodeRepositoryNotFoundException {
			// Repository doesn't exist, create it
			log.Printf("[DEBUG] ECR - Creating repository %s for template %s", templateRepo, templateID)
			_, err = ecrClient.CreateRepository(&ecr.CreateRepositoryInput{
				RepositoryName: aws.String(templateRepo),
				ImageTagMutability: aws.String(ecr.ImageTagMutabilityMutable),
			})
			if err != nil {
				return fmt.Errorf("failed to create ECR repository: %v", err)
			}
			log.Printf("[DEBUG] ECR - Repository %s created successfully", templateRepo)
			return nil
		}
		return fmt.Errorf("failed to check ECR repository: %v", err)
	}
	
	// Repository exists
	log.Printf("[DEBUG] ECR - Repository %s already exists", templateRepo)
	return nil
}

// GetAWSECRAuthToken retrieves an authentication token for AWS ECR
func GetAWSECRAuthToken() (*AWSAuthResponse, error) {
	// Get AWS session
	sess, err := constants.GetAWSSession()
	if err != nil {
		return nil, fmt.Errorf("failed to get AWS session: %v", err)
	}

	// 确保会话有区域信息
	if sess.Config.Region == nil || *sess.Config.Region == "" {
		region, err := constants.GetAWSRegion()
		if err != nil {
			return nil, fmt.Errorf("failed to get AWS region: %v", err)
		}
		
		// 使用获取到的区域创建新的会话
		newConfig := aws.Config{
			Region: aws.String(region),
		}
		if sess.Config.Credentials != nil {
			newConfig.Credentials = sess.Config.Credentials
		}
		
		newSess, err := session.NewSession(&newConfig)
		if err != nil {
			return nil, fmt.Errorf("failed to create AWS session with region: %v", err)
		}
		sess = newSess
	}

	// Create ECR client
	ecrClient := ecr.New(sess)

	// Get authorization token
	input := &ecr.GetAuthorizationTokenInput{}
	result, err := ecrClient.GetAuthorizationToken(input)
	if err != nil {
		log.Printf("[ERROR] ECR Auth - Failed to get token: %v", err)
		return nil, fmt.Errorf("failed to get ECR authorization token: %v", err)
	}

	if len(result.AuthorizationData) == 0 {
		log.Printf("[ERROR] ECR Auth - No authorization data returned")
		return nil, fmt.Errorf("no authorization data returned from ECR")
	}

	authData := result.AuthorizationData[0]
	log.Printf("[DEBUG] ECR Auth - Got token expiring at: %s", authData.ExpiresAt.Format(time.RFC3339))
	log.Printf("[DEBUG] ECR Auth - Proxy endpoint: %s", *authData.ProxyEndpoint)
	
	// 测试令牌有效性
	testClient := &http.Client{
		Timeout: 5 * time.Second,
	}
	testReq, _ := http.NewRequest("GET", fmt.Sprintf("%s/v2/", *authData.ProxyEndpoint), nil)
	testReq.Header.Set("Authorization", fmt.Sprintf("Basic %s", *authData.AuthorizationToken))
	testResp, testErr := testClient.Do(testReq)
	if testErr != nil {
		log.Printf("[ERROR] ECR Auth - Token test failed: %v", testErr)
	} else {
		defer testResp.Body.Close()
		log.Printf("[INFO] ECR Auth - Token test status: %d", testResp.StatusCode)
		if testResp.StatusCode == http.StatusOK {
			log.Printf("[INFO] ECR Auth - Token is valid")
		} else {
			respBody, _ := io.ReadAll(testResp.Body)
			log.Printf("[ERROR] ECR Auth - Token test failed: %s", string(respBody))
		}
	}
	
	// 验证令牌格式
	decodedToken, err := base64.StdEncoding.DecodeString(*authData.AuthorizationToken)
	if err != nil {
		log.Printf("[ERROR] ECR Auth - Failed to decode token: %v", err)
		return nil, fmt.Errorf("failed to decode ECR authorization token: %v", err)
	}
	
	tokenStr := string(decodedToken)
	if !strings.Contains(tokenStr, ":") {
		log.Printf("[ERROR] ECR Auth - Invalid token format")
		return nil, fmt.Errorf("invalid ECR token format")
	}
	
	// Important: For AWS ECR, we return the raw base64 encoded token
	// This will be used directly in the Basic auth header
	return &AWSAuthResponse{
		Token:         *authData.AuthorizationToken,
		ExpiresAt:     *authData.ExpiresAt,
		ProxyEndpoint: *authData.ProxyEndpoint,
	}, nil
}

// HandleAWSECRToken handles the token request for AWS ECR
func HandleAWSECRToken(w http.ResponseWriter, req *http.Request) (string, error) {
	log.Printf("[DEBUG] ECR Token - Handling token request")
	
	// Extract template ID from the request
	scope := req.URL.Query().Get("scope")
	templateID := ""
	if scope != "" {
		// Extract template ID from scope
		// Format: repository:e2b/custom-envs/{templateID}:push,pull
		parts := strings.Split(scope, ":")
		if len(parts) >= 2 {
			repoPath := parts[1]
			pathParts := strings.Split(repoPath, "/")
			if len(pathParts) >= 3 {
				templateID = pathParts[2]
				log.Printf("[DEBUG] ECR Token - Extracted template ID: %s", templateID)
				
				// Ensure repository exists for this template
				err := EnsureECRRepositoryExists(templateID)
				if err != nil {
					log.Printf("Error ensuring ECR repository exists: %v", err)
					http.Error(w, "Failed to ensure ECR repository exists", http.StatusInternalServerError)
					return "", err
				}
			}
		}
	}
	
	authResponse, err := GetAWSECRAuthToken()
	if err != nil {
		log.Printf("Error getting AWS ECR auth token: %v", err)
		http.Error(w, "Failed to get ECR authorization token", http.StatusInternalServerError)
		return "", err
	}

	// For Docker client compatibility, we need to decode the token
	// to extract the password part for the client response
	log.Printf("[DEBUG] ECR Token - Using token (length: %d)", len(authResponse.Token))

	// Create a response similar to Docker Registry v2 token response
	// 直接返回完整的 base64 编码令牌
	tokenResponse := map[string]interface{}{
		"token":      authResponse.Token, // 返回完整的 base64 编码令牌
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

	log.Printf("[DEBUG] ECR Token - Successfully returned token response")
	
	// 返回完整的base64编码令牌，用于Basic认证
	// 这将在代理请求时使用
	return authResponse.Token, nil
}

// Helper function to get the minimum of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
