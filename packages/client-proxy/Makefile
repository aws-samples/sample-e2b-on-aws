IMAGE := e2b-orchestration/client-proxy

.PHONY: build
build:
	# Allow for passing commit sha directly for docker builds
	$(eval COMMIT_SHA ?= $(shell git rev-parse --short HEAD))
	CGO_ENABLED=0 GOOS=linux go build -o bin/client-proxy -ldflags "-X=main.commitSHA=$(COMMIT_SHA)" .

.PHONY: build-and-upload
build-and-upload:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	@rm -rf .shared/
	@cp -r ../shared .shared/
	@docker buildx install # sets up the buildx as default docker builder (otherwise the command below won't work)
	@docker build --platform linux/amd64 --tag "$(GCP_REGION)-docker.pkg.dev/$(GCP_PROJECT_ID)/$(IMAGE)" --push --build-arg COMMIT_SHA="$(COMMIT_SHA)" .
	@rm -rf .shared/

openapi := ../../spec/openapi-edge.yml
codegen := go tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen

.PHONY: generate
generate:
	$(codegen) -old-config-style -generate gin --package api $(openapi) > ../shared/pkg/http/edge/api.gen.go
	$(codegen) -old-config-style -generate types --package api $(openapi) > ../shared/pkg/http/edge/types.gen.go
	$(codegen) -old-config-style -generate spec --package api $(openapi) > ../shared/pkg/http/edge/spec.gen.go
	$(codegen) -old-config-style -generate client --package api $(openapi) > ../shared/pkg/http/edge/client.gen.go

.PHONY: test
test:
	go test -v ./...


.PHONY: build-and-upload-aws
build-and-upload-aws:
	$(eval AWS_ACCOUNT_ID := $(shell grep "^account_id=" /opt/config.properties | cut -d= -f2))
	$(eval AWS_REGION := $(shell grep "^AWSREGION=" /opt/config.properties | cut -d= -f2))
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))

	@rm -rf .shared/
	@cp -r ../shared .shared/
	@docker buildx install || true # sets up the buildx as default docker builder
	# Create ECR repository if it doesn't exist
	@aws ecr describe-repositories --repository-names $(IMAGE) || aws ecr create-repository --repository-name $(IMAGE)
	# Login to ECR
	@aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	# Build and push the image
	@echo "Building for architecture: $(ARCHITECTURE)"

	@if [ "$(ARCHITECTURE)" = "arm64" ]; then \
		echo "Building for ARM64 architecture"; \
		docker build --platform linux/arm64 --tag "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest" .; \
	else \
		echo "Building for x86_64 architecture"; \
		docker build --platform linux/amd64 --tag "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest" .; \
	fi

	@docker push "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest"
	@rm -rf .shared/