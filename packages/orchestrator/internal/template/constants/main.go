package constants

import (
	"fmt"
	"strings"

	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

func CheckRequired() error {
	var missing []string

	if consts.AWSAccountID == "" {
		missing = append(missing, "AWS_ACCOUNT_ID")
	}

	if consts.ECRRepository == "" {
		missing = append(missing, "AWS_ECR_REPOSITORY")
	}

	// if consts.AWS_ACCESS_KEY_ID == "" {
	// 	missing = append(missing, "AWS_ACCESS_KEY_ID")
	// }

	if consts.AWSRegion == "" {
		missing = append(missing, "AWS_REGION")
	}

	if len(missing) > 0 {
		return fmt.Errorf("missing environment variables: %s", strings.Join(missing, ", "))
	}

	return nil
}
