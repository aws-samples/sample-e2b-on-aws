package constants

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
)

var (
	// AWS environment variables
	AWSRegion         = os.Getenv("AWS_REGION")
	AWSECRRepository  = os.Getenv("AWS_ECR_REPOSITORY_NAME")
	AWSAccessKeyID    = os.Getenv("AWS_ACCESS_KEY_ID")
	AWSSecretAccessKey = os.Getenv("AWS_SECRET_ACCESS_KEY")
	AWSAccountID      = os.Getenv("AWS_ACCOUNT_ID")

	// AWS dynamic configuration
	awsAccountID    string
	awsRegion       string
	awsRegistryHost string
	awsUploadPrefix string

	awsConfigOnce sync.Once
	awsConfigErr  error
	awsSession    *session.Session
)

// getRegionFromEC2Metadata attempts to retrieve region info from the EC2 instance metadata service
func getRegionFromEC2Metadata() (string, error) {
	client := &http.Client{
		Timeout: 2 * time.Second, // Set a short timeout
	}
	
	resp, err := client.Get("http://169.254.169.254/latest/meta-data/placement/region")
	if err != nil {
		return "", fmt.Errorf("failed to get region from EC2 metadata: %v", err)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("EC2 metadata service returned non-OK status: %d", resp.StatusCode)
	}
	
	regionBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read region from EC2 metadata: %v", err)
	}
	
	region := string(regionBytes)
	if region == "" {
		return "", fmt.Errorf("empty region from EC2 metadata")
	}
	
	return region, nil
}

// InitAWSConfig initializes AWS configuration
func InitAWSConfig() error {
	awsConfigOnce.Do(func() {
		// Create AWS session
		config := &aws.Config{}

		// Handle region configuration
		if AWSRegion != "" {
			// If region is provided via environment variable, use it directly
			config.Region = aws.String(AWSRegion)
			log.Printf("Using region from environment variable: %s", AWSRegion)
		} else {
			// Try to get region from EC2 metadata
			metadataRegion, err := getRegionFromEC2Metadata()
			if err == nil && metadataRegion != "" {
				config.Region = aws.String(metadataRegion)
				log.Printf("Using region from EC2 metadata: %s", metadataRegion)
			} else {
				log.Printf("Could not get region from EC2 metadata: %v", err)
			}
		}

		// Handle credentials configuration
		if AWSAccessKeyID != "" && AWSSecretAccessKey != "" {
			config.Credentials = credentials.NewStaticCredentials(
				AWSAccessKeyID,
				AWSSecretAccessKey,
				"",
			)
			log.Printf("Using AWS credentials from environment variables")
		}

		// Create AWS session
		var err error
		awsSession, err = session.NewSession(config)
		if err != nil {
			awsConfigErr = fmt.Errorf("failed to create AWS session: %v", err)
			return
		}

		// Get AWS account ID
		if AWSAccountID != "" {
			awsAccountID = AWSAccountID
		} else {
			// Get account ID via STS
			stsClient := sts.New(awsSession)
			result, err := stsClient.GetCallerIdentity(&sts.GetCallerIdentityInput{})
			if err != nil {
				awsConfigErr = fmt.Errorf("failed to get AWS account ID: %v", err)
				return
			}
			awsAccountID = *result.Account
		}

		// Determine the final region to use
		if AWSRegion != "" {
			awsRegion = AWSRegion
		} else if awsSession.Config.Region != nil && *awsSession.Config.Region != "" {
			awsRegion = *awsSession.Config.Region
			log.Printf("Using region from AWS session: %s", awsRegion)
		} else {
			// If region is still unavailable, use the default region
			awsRegion = "us-east-1" // default region
			log.Printf("No region found, using default: %s", awsRegion)
		}

		// Set the registry host
		awsRegistryHost = fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com", awsAccountID, awsRegion)
	})

	return awsConfigErr
}

// GetAWSSession returns the AWS session
func GetAWSSession() (*session.Session, error) {
	if err := InitAWSConfig(); err != nil {
		return nil, err
	}
	return awsSession, nil
}

// GetAWSAccountID returns the AWS account ID
func GetAWSAccountID() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsAccountID, nil
}

// GetAWSRegion returns the AWS region
func GetAWSRegion() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsRegion, nil
}

// GetAWSRegistryHost returns the AWS ECR registry host
func GetAWSRegistryHost() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsRegistryHost, nil
}

// GetAWSUploadPrefix returns the AWS ECR upload prefix
// Uses the base_repo_name/template_id format for the repository name
func GetAWSUploadPrefix(templateID string) (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	
	// Use the base_repo_name/template_id format for the repository name
	templateRepo := fmt.Sprintf("%s/%s", AWSECRRepository, templateID)

	// Return the upload prefix
	return fmt.Sprintf("/v2/%s/blobs/uploads/", templateRepo), nil
}
