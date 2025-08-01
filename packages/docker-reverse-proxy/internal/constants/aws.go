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

// 尝试从 EC2 实例元数据服务获取区域信息
func getRegionFromEC2Metadata() (string, error) {
	client := &http.Client{
		Timeout: 2 * time.Second, // 设置较短的超时时间
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

// InitAWSConfig 初始化 AWS 配置信息
func InitAWSConfig() error {
	awsConfigOnce.Do(func() {
		// 创建 AWS 会话
		config := &aws.Config{}

		// 处理区域配置
		if AWSRegion != "" {
			// 如果环境变量中提供了区域，直接使用
			config.Region = aws.String(AWSRegion)
			log.Printf("Using region from environment variable: %s", AWSRegion)
		} else {
			// 尝试从 EC2 元数据获取区域
			metadataRegion, err := getRegionFromEC2Metadata()
			if err == nil && metadataRegion != "" {
				config.Region = aws.String(metadataRegion)
				log.Printf("Using region from EC2 metadata: %s", metadataRegion)
			} else {
				log.Printf("Could not get region from EC2 metadata: %v", err)
			}
		}

		// 处理凭证配置
		if AWSAccessKeyID != "" && AWSSecretAccessKey != "" {
			config.Credentials = credentials.NewStaticCredentials(
				AWSAccessKeyID,
				AWSSecretAccessKey,
				"",
			)
			log.Printf("Using AWS credentials from environment variables")
		}

		// 创建 AWS 会话
		var err error
		awsSession, err = session.NewSession(config)
		if err != nil {
			awsConfigErr = fmt.Errorf("failed to create AWS session: %v", err)
			return
		}

		// 获取 AWS 账户 ID
		if AWSAccountID != "" {
			awsAccountID = AWSAccountID
		} else {
			// 通过 STS 获取账户 ID
			stsClient := sts.New(awsSession)
			result, err := stsClient.GetCallerIdentity(&sts.GetCallerIdentityInput{})
			if err != nil {
				awsConfigErr = fmt.Errorf("failed to get AWS account ID: %v", err)
				return
			}
			awsAccountID = *result.Account
		}

		// 确定最终使用的区域
		if AWSRegion != "" {
			awsRegion = AWSRegion
		} else if awsSession.Config.Region != nil && *awsSession.Config.Region != "" {
			awsRegion = *awsSession.Config.Region
			log.Printf("Using region from AWS session: %s", awsRegion)
		} else {
			// 如果仍然无法获取区域，使用默认区域
			awsRegion = "us-east-1" // 默认区域
			log.Printf("No region found, using default: %s", awsRegion)
		}

		// 设置注册表主机
		awsRegistryHost = fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com", awsAccountID, awsRegion)
	})

	return awsConfigErr
}

// GetAWSSession 返回 AWS 会话
func GetAWSSession() (*session.Session, error) {
	if err := InitAWSConfig(); err != nil {
		return nil, err
	}
	return awsSession, nil
}

// GetAWSAccountID 返回 AWS 账户 ID
func GetAWSAccountID() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsAccountID, nil
}

// GetAWSRegion 返回 AWS 区域
func GetAWSRegion() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsRegion, nil
}

// GetAWSRegistryHost 返回 AWS ECR 注册表主机
func GetAWSRegistryHost() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsRegistryHost, nil
}

// GetAWSUploadPrefix 返回 AWS ECR 上传前缀
// 使用 base_repo_name/template_id 格式的仓库名称
func GetAWSUploadPrefix(templateID string) (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	
	// 使用 base_repo_name/template_id 格式的仓库名称
	templateRepo := fmt.Sprintf("%s/%s", AWSECRRepository, templateID)
	
	// 返回上传前缀
	return fmt.Sprintf("/v2/%s/blobs/uploads/", templateRepo), nil
}
