package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"

	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/constants"
	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/handlers"
	"github.com/e2b-dev/infra/packages/docker-reverse-proxy/internal/utils"
	"github.com/e2b-dev/infra/packages/shared/pkg/consts"
)

var commitSHA string

func main() {
	err := constants.CheckRequired()
	if err != nil {
		log.Fatal(err)
	}

	port := flag.Int("port", 5000, "Port for test HTTP server")
	flag.Parse()

	log.Println("Starting docker reverse proxy", "commit", commitSHA, "cloud provider", constants.CurrentCloudProvider)

	store := handlers.NewStore()

	// https://distribution.github.io/distribution/spec/api/
	http.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		path := req.URL.String()
		log.Printf("Request: %s %s\n", req.Method, utils.SubstringMax(path, 100))

		// Health check for nomad
		if req.URL.Path == "/health" {
			store.HealthCheck(w, req)
			return
		}

		// Handle PATCH requests for artifact uploads based on cloud provider
		if req.Method == http.MethodPatch {
			if constants.CurrentCloudProvider == constants.GCP && strings.HasPrefix(path, constants.GCPArtifactUploadPrefix) {
				store.ServeHTTP(w, req)
				return
			} else if constants.CurrentCloudProvider == constants.AWS {
				// Get AWS upload prefix
				uploadPrefix, err := consts.GetAWSUploadPrefix()
				if err != nil {
					log.Printf("Failed to get AWS upload prefix: %v", err)
					w.WriteHeader(http.StatusInternalServerError)
					return
				}
				
				if strings.HasPrefix(path, uploadPrefix) {
					store.ServeHTTP(w, req)
					return
				}
			}
		}

		// https://docker-docs.uclv.cu/registry/spec/auth/oauth/
		// We are using Token validation, and not OAuth2, so we need to return 404 for the POST /v2/token endpoint
		if req.URL.Path == "/v2/token" && req.Method == http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}

		// If the request doesn't have the Authorization header, we return 401 with the url for getting a token
		if req.Header.Get("Authorization") == "" {
			log.Printf("Authorization header is missing: %s\n", utils.SubstringMax(path, 100))
			utils.SetDockerUnauthorizedHeaders(w)

			return
		}

		// Get token to access the Docker repository
		if req.URL.Path == "/v2/token" {
			err = store.GetToken(w, req)
			if err != nil {
				log.Printf("Error while getting token: %s\n", err)
			}
			return
		}

		// Verify if the user is logged in with the token
		// https://distribution.github.io/distribution/spec/api/#api-version-check
		if req.URL.Path == "/v2/" {
			err = store.LoginWithToken(w, req)
			if err != nil {
				log.Printf("Error while logging in with token: %s\n", err)
			}

			return
		}

		// Proxy all other requests
		store.Proxy(w, req)
	})

	log.Printf("Starting server on port: %d\n", *port)
	log.Fatal(http.ListenAndServe(fmt.Sprintf(":%s", strconv.Itoa(*port)), nil))
}
