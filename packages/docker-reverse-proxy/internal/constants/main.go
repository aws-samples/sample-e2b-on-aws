package constants

import (
	"fmt"
	"os"
	"strings"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

// CloudProvider represents the cloud provider type
type CloudProvider string

const (
	GCP CloudProvider = "gcp"
	AWS CloudProvider = "aws"
)

// Current cloud provider based on environment variable
var CurrentCloudProvider = getCloudProvider()

func getCloudProvider() CloudProvider {
	provider := os.Getenv("CLOUD_PROVIDER")
	if provider == "aws" {
		return AWS
	}
	return GCP // Default to GCP if not specified
}

func CheckRequired() error {
	var missing []string

	// Common required variables
	if consts.Domain == "" {
		missing = append(missing, "DOMAIN_NAME")
	}

	// Check GCP specific variables if GCP is the provider
	if CurrentCloudProvider == GCP {
		if consts.GCPProject == "" {
			missing = append(missing, "GCP_PROJECT_ID")
		}

		if consts.DockerRegistry == "" {
			missing = append(missing, "GCP_DOCKER_REPOSITORY_NAME")
		}

		if consts.GoogleServiceAccountSecret == "" {
			missing = append(missing, "GOOGLE_SERVICE_ACCOUNT_BASE64")
		}

		if consts.GCPRegion == "" {
			missing = append(missing, "GCP_REGION")
		}
	}

	// Check AWS specific variables if AWS is the provider
	if CurrentCloudProvider == AWS {
		if AWSECRRepository == "" {
			missing = append(missing, "AWS_ECR_REPOSITORY_NAME")
		}

		// Initialize AWS config to check if we can get the required information
		if err := InitAWSConfig(); err != nil {
			return fmt.Errorf("failed to initialize AWS config: %v", err)
		}
	}

	if len(missing) > 0 {
		return fmt.Errorf("missing environment variables: %s", strings.Join(missing, ", "))
	}

	return nil
}

var GCPArtifactUploadPrefix = fmt.Sprintf("/artifacts-uploads/namespaces/%s/repositories/%s/uploads/", consts.GCPProject, consts.DockerRegistry)
