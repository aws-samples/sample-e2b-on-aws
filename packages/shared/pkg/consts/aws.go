package consts

import (
	"fmt"
	"os"
	"sync"

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

// InitAWSConfig 初始化 AWS 配置信息
func InitAWSConfig() error {
	awsConfigOnce.Do(func() {
		// 创建 AWS 会话
		config := &aws.Config{}

		// 只有在提供了区域时才设置
		if AWSRegion != "" {
			config.Region = aws.String(AWSRegion)
		}

		// 只有在提供了访问密钥和秘密密钥时才设置
		if AWSAccessKeyID != "" && AWSSecretAccessKey != "" {
			config.Credentials = credentials.NewStaticCredentials(
				AWSAccessKeyID,
				AWSSecretAccessKey,
				"",
			)
		}

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

		// 设置区域
		if AWSRegion != "" {
			awsRegion = AWSRegion
		} else if awsSession.Config.Region != nil && *awsSession.Config.Region != "" {
			awsRegion = *awsSession.Config.Region
		} else {
			awsRegion = "us-east-1" // 默认区域
		}

		// 设置注册表主机和上传前缀
		awsRegistryHost = fmt.Sprintf("%s.dkr.ecr.%s.amazonaws.com", awsAccountID, awsRegion)
		awsUploadPrefix = fmt.Sprintf("/v2/%s/%s/blobs/uploads/", awsAccountID, AWSECRRepository)
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
func GetAWSUploadPrefix() (string, error) {
	if err := InitAWSConfig(); err != nil {
		return "", err
	}
	return awsUploadPrefix, nil
}
