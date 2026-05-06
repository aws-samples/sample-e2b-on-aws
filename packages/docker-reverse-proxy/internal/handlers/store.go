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
		// Rewrite ECR-returned Location header so the Docker client continues through the proxy
		if loc := resp.Header.Get("Location"); loc != "" {
			registryHost, err := constants.GetAWSRegistryHost()
			if err == nil && constants.CurrentCloudProvider == constants.AWS {
				baseRepo := strings.Trim(constants.AWSECRRepository, "/")
				ecrPrefix := "/v2/" + baseRepo + "/"
				proxyPrefix := "/v2/e2b/custom-envs/"

				newLoc := loc
				// Strip the ECR hostname (convert to relative path)
				ecrSchemeHost := "https://" + registryHost
				newLoc = strings.TrimPrefix(newLoc, ecrSchemeHost)
				// Convert ECR path back to proxy path
				newLoc = strings.Replace(newLoc, ecrPrefix, proxyPrefix, 1)

				if newLoc != loc {
					resp.Header.Set("Location", newLoc)
					log.Printf("[DEBUG] ModifyResponse - Rewrote Location: %s -> %s", loc, newLoc)
				}
			}
		}

		// Log all responses, with special attention to error responses
		if resp.StatusCode >= 400 {
			log.Printf("[ERROR] Proxy Response - Status: %d, URL: %s, Method: %s", 
				resp.StatusCode, resp.Request.URL, resp.Request.Method)
			
			// Read response body
			respBody, err := io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("[ERROR] Failed to read response body: %v", err)
				return nil
			}
			
			bodyStr := string(respBody)
			
			// Log detailed error information
			log.Printf("[ERROR] Detailed error response [%d] for %s %s:", 
				resp.StatusCode, resp.Request.Method, resp.Request.URL)
			log.Printf("[ERROR] Response body: %s", bodyStr)
			
			// Specifically check for authentication errors
			if resp.StatusCode == http.StatusUnauthorized {
				log.Printf("[ERROR] Authentication error detected!")
				
				// Check if it contains a "Not Authorized" error
				if strings.Contains(bodyStr, "Not Authorized") {
					log.Printf("[ERROR] ECR Not Authorized error detected!")
					
					// Log request headers
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
			
			// Log request headers (excluding the full authorization token)
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
			
			// Log response headers
			log.Printf("[ERROR] Response headers:")
			for name, values := range resp.Header {
				log.Printf("[ERROR]   %s: %v", name, values)
			}
			
			// Create a new reader with the same content for downstream handlers
			resp.Body = io.NopCloser(strings.NewReader(bodyStr))
		}

		return nil
	}

	// Add custom director function for more control
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		
		// Only log basic request information
		log.Printf("[INFO] Proxy Director - Forwarding request to: %s %s", 
			req.Method, req.URL.String())
		
		// For PUT requests with a digest parameter, log special debug info
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
