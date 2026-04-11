package handlers

import (
	"fmt"
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
		// 重写 ECR 返回的 Location header，确保 Docker client 继续通过 proxy
		if loc := resp.Header.Get("Location"); loc != "" {
			registryHost, err := constants.GetAWSRegistryHost()
			if err == nil && constants.CurrentCloudProvider == constants.AWS {
				baseRepo := strings.Trim(constants.AWSECRRepository, "/")
				ecrPrefix := "/v2/" + baseRepo + "/"
				proxyPrefix := "/v2/e2b/custom-envs/"

				newLoc := loc
				// 去掉 ECR 主机名（变成相对路径）
				ecrSchemeHost := "https://" + registryHost
				newLoc = strings.TrimPrefix(newLoc, ecrSchemeHost)
				// ECR 路径转回 proxy 路径
				newLoc = strings.Replace(newLoc, ecrPrefix, proxyPrefix, 1)

				if newLoc != loc {
					resp.Header.Set("Location", newLoc)
					log.Printf("[DEBUG] ModifyResponse - Rewrote Location: %s -> %s", loc, newLoc)
				}
			}
		}

		// 记录所有响应，特别关注错误响应
		if resp.StatusCode >= 400 {
			log.Printf("[ERROR] Proxy Response - Status: %d, URL: %s, Method: %s",
				resp.StatusCode, resp.Request.URL, resp.Request.Method)

			// Preserve signal for auth failures without logging sensitive request or response values.
			if resp.StatusCode == http.StatusUnauthorized {
				log.Printf("[ERROR] Authentication error detected!")
			}
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
