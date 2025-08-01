ENV := $(shell cat ../../.last_used_env || echo "not-set")
-include ../../.env.${ENV}

IMAGE := docker-reverse-proxy

.PHONY: build
build:
	# Allow for passing commit sha directly for docker builds
	$(eval COMMIT_SHA ?= $(shell git rev-parse --short HEAD))
	CGO_ENABLED=0 go build -o bin/docker-reverse-proxy -ldflags "-X=main.commitSHA=$(COMMIT_SHA)" .

.PHONY: build-debug
build-debug:
	CGO_ENABLED=1 go build -race -gcflags=all="-N -l" -o bin/docker-reverse-proxy .

.PHONY: build-and-upload
build-and-upload:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	@cp -r ../shared .shared/
	@docker buildx install # sets up the buildx as default docker builder (otherwise the command below won't work)
	@docker build --platform linux/amd64 --tag "$(GCP_REGION)-docker.pkg.dev/$(GCP_PROJECT_ID)/$(IMAGE)" --push --build-arg COMMIT_SHA="$(COMMIT_SHA)" .
	@rm -rf .shared/

.PHONY: test
test:
	go test -v ./...


.PHONY: build-and-upload-aws
build-and-upload-aws:
	$(eval AWS_ACCOUNT_ID := $(shell grep "^account_id=" /opt/config.properties | cut -d= -f2))
	$(eval AWS_REGION := $(shell grep "^AWSREGION=" /opt/config.properties | cut -d= -f2))
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	# Create ECR repository if it doesn't exist
	@aws ecr describe-repositories --repository-names $(IMAGE) || aws ecr create-repository --repository-name $(IMAGE)
	# Login to ECR
	@aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	@cp -r ../shared .shared/
	@docker buildx install # sets up the buildx as default docker builder (otherwise the command below won't work)
	@docker build --platform linux/amd64 --tag "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest" --push --build-arg COMMIT_SHA="$(COMMIT_SHA)" .
	# Build and push the image
	@echo "Building for architecture: $(ARCHITECTURE)"
	@docker build --platform linux/amd64 --tag "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest" .
	@docker push "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest"
	@rm -rf .shared/