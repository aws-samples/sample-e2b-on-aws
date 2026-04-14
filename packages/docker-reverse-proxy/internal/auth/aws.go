package auth

import (
	"encoding/base64"
	"fmt"
	"log"
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
				RepositoryName:     aws.String(templateRepo),
				ImageTagMutability: aws.String(ecr.ImageTagMutabilityImmutable),
				ImageScanningConfiguration: &ecr.ImageScanningConfiguration{
					ScanOnPush: aws.Bool(true),
				},
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
