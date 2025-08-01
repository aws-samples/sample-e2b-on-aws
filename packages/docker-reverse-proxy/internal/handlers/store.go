package handlers

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"

	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/cache"
	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/constants"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
	"github.com/e2b-dev/infra/packages/shared/pkg/db"
)

type APIStore struct {
	db        *db.DB
	AuthCache *cache.AuthCache
	proxy     *httputil.ReverseProxy
}

func NewStore() *APIStore {
	authCache := cache.New()
	database, err := db.NewClient(3, 2)
	if err != nil {
		log.Fatal(err)
	}

	var targetUrl *url.URL

	// Set the target URL based on the cloud provider
	if constants.CurrentCloudProvider == constants.GCP {
		targetUrl = &url.URL{
			Scheme: "https",
			Host:   fmt.Sprintf("%s-docker.pkg.dev", consts.GCPRegion),
		}
		log.Printf("[DEBUG] Store - Using GCP target URL: %s", targetUrl)
	} else if constants.CurrentCloudProvider == constants.AWS {
		// Get AWS registry host
		registryHost, err := constants.GetAWSRegistryHost()
		if err != nil {
			log.Fatalf("Failed to get AWS registry host: %v", err)
		}
		
		targetUrl = &url.URL{
			Scheme: "https",
			Host:   registryHost,
		}
		log.Printf("[DEBUG] Store - Using AWS target URL: %s", targetUrl)
		
		// Get additional AWS info for debugging
		accountID, _ := constants.GetAWSAccountID()
		region, _ := constants.GetAWSRegion()
		log.Printf("[DEBUG] Store - AWS Account ID: %s, Region: %s, Repository: %s", 
			accountID, region, constants.AWSECRRepository)
	} else {
		log.Fatal("Unsupported cloud provider")
	}

	proxy := httputil.NewSingleHostReverseProxy(targetUrl)

	// Custom ModifyResponse function
	proxy.ModifyResponse = func(resp *http.Response) error {
		// 记录所有响应，特别关注错误响应
		if resp.StatusCode >= 400 {
			log.Printf("[ERROR] Proxy Response - Status: %d, URL: %s, Method: %s", 
				resp.StatusCode, resp.Request.URL, resp.Request.Method)
			
			// 读取响应体
			respBody, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("[ERROR] Failed to read response body: %v", err)
				return nil
			}
			
			bodyStr := string(respBody)
			
			// 记录详细的错误信息
			log.Printf("[ERROR] Detailed error response [%d] for %s %s:", 
				resp.StatusCode, resp.Request.Method, resp.Request.URL)
			log.Printf("[ERROR] Response body: %s", bodyStr)
			
			// 特别检查认证错误
			if resp.StatusCode == http.StatusUnauthorized {
				log.Printf("[ERROR] Authentication error detected!")
				
				// 检查是否包含 "Not Authorized" 错误
				if strings.Contains(bodyStr, "Not Authorized") {
					log.Printf("[ERROR] ECR Not Authorized error detected!")
					
					// 记录请求头信息
					log.Printf("[ERROR] Request headers:")
					for name, values := range resp.Request.Header {
						if name == "Authorization" {
							authParts := strings.Split(values[0], " ")
							if len(authParts) >= 2 {
								log.Printf("[ERROR]   %s: %s ***", name, authParts[0])
							} else {
								log.Printf("[ERROR]   %s: ***", name)
							}
						} else {
							log.Printf("[ERROR]   %s: %v", name, values)
						}
					}
				}
			}
			log.Printf("[ERROR] Detailed error response [%d] for %s %s:", 
				resp.StatusCode, resp.Request.Method, resp.Request.URL)
			log.Printf("[ERROR] Response body: %s", bodyStr)
			
			// 记录请求头信息（不包括完整的授权令牌）
			log.Printf("[ERROR] Request headers:")
			for name, values := range resp.Request.Header {
				if name == "Authorization" {
					authParts := strings.Split(values[0], " ")
					if len(authParts) >= 2 {
						log.Printf("[ERROR]   %s: %s ***", name, authParts[0])
					} else {
						log.Printf("[ERROR]   %s: ***", name)
					}
				} else {
					log.Printf("[ERROR]   %s: %v", name, values)
				}
			}
			
			// 记录响应头信息
			log.Printf("[ERROR] Response headers:")
			for name, values := range resp.Header {
				log.Printf("[ERROR]   %s: %v", name, values)
			}
			
			// 创建一个新的读取器，包含相同的内容供下一个处理程序使用
			resp.Body = io.NopCloser(strings.NewReader(bodyStr))
		}

		return nil
	}

	// Add custom director function for more control
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		
		// 只记录基本请求信息
		log.Printf("[INFO] Proxy Director - Forwarding request to: %s %s", 
			req.Method, req.URL.String())
		
		// 对于PUT请求和digest参数，记录特殊调试信息
		if req.Method == http.MethodPut && req.URL.Query().Get("digest") != "" {
			log.Printf("[INFO] Proxy Director - PUT request with digest: %s", req.URL.Query().Get("digest"))
		}
	}

	return &APIStore{
		db:        database,
		AuthCache: authCache,
		proxy:     proxy,
	}
}

func (a *APIStore) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	// Set the host to the URL host
	req.Host = req.URL.Host
	log.Printf("[INFO] ServeHTTP - Proxying request to: %s %s", req.Method, req.URL.String())
	
	a.proxy.ServeHTTP(rw, req)
}
