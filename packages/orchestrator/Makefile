client := gcloud compute instances list --format='csv(name)' --project $(GCP_PROJECT_ID) | grep "client"

.PHONY: init
init:
	brew install protobuf
	go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.28
	go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.2

.PHONY: generate
generate:
	# You need to install protobuf (brew install protobuf) and following go packages: protoc-gen-go, protoc-gen-go-grpc
	# https://grpc.io/docs/languages/go/quickstart/
	@echo "Generating..."
	@protoc --go_out=../shared/pkg/grpc/orchestrator/ --go_opt=paths=source_relative --go-grpc_out=../shared/pkg/grpc/orchestrator/ --go-grpc_opt=paths=source_relative orchestrator.proto
	@echo "Done"

.PHONY: build
build:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))
	@rm -rf .shared/
	@cp -r ../shared .shared/
	@echo "Building with Docker workspace module approach for architecture: $(ARCHITECTURE)"

	@docker build --platform linux/$(ARCHITECTURE) --output=bin --build-arg COMMIT_SHA="$(COMMIT_SHA)" .
	@rm -rf .shared/

.PHONY: build-local
build-local:
	# Allow for passing commit sha directly for docker builds
	$(eval COMMIT_SHA ?= $(shell git rev-parse --short HEAD))
	
	CGO_ENABLED=1 GOOS=linux go build -o bin/orchestrator -ldflags "-X=main.commitSHA=$(COMMIT_SHA)" .

.PHONY: build-debug
build-debug:
	CGO_ENABLED=1 GOOS=linux go build -race -gcflags=all="-N -l" -o bin/orchestrator .

.PHONY: run-debug
run-debug:
	make build-debug
	sudo -E GOTRACEBACK=crash \
	GODEBUG=madvdontneed=1 \
	NODE_ID="testclient" \
	TEMPLATE_BUCKET_NAME=$(TEMPLATE_BUCKET_NAME) \
	ENVD_TIMEOUT=$(ENVD_TIMEOUT) \
	ORCHESTRATOR_SERVICES=$(ORCHESTRATOR_SERVICES) \
	GCP_DOCKER_REPOSITORY_NAME=$(GCP_DOCKER_REPOSITORY_NAME) \
	GOOGLE_SERVICE_ACCOUNT_BASE64=$(GOOGLE_SERVICE_ACCOUNT_BASE64) \
	./bin/orchestrator

.PHONY: upload-aws
upload-aws:
	@echo "AWS_REGION is $(AWS_REGION)"
	# Create repository if it doesn't exist
	$(eval IMAGE := e2b-orchestration/orchestrator)
	@echo "Using region: us-east-1"
	# aws ecr describe-repositories --repository-names $(IMAGE) --region us-east-1 || \
	# aws ecr create-repository --repository-name $(IMAGE) --region us-east-1
	# Login to ECR
	aws ecr get-login-password --region us-east-1 | sudo docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.us-east-1.amazonaws.com
	# Build and push Docker image
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	sudo docker buildx install || true # sets up the buildx as default docker builder
	sudo docker build --platform linux/amd64 --tag "$(AWS_ACCOUNT_ID).dkr.ecr.us-east-1.amazonaws.com/$(IMAGE):latest" --build-arg COMMIT_SHA="$(COMMIT_SHA)" .
	sudo docker push "$(AWS_ACCOUNT_ID).dkr.ecr.us-east-1.amazonaws.com/$(IMAGE):latest"

.PHONY: upload
upload:
	@if [ -n "$(GCP_PROJECT_ID)" ] && [ -n "$(GCP_REGION)" ]; then \
		$(MAKE) upload-gcp; \
	elif [ -n "$(AWS_ACCOUNT_ID)" ] && [ -n "$(AWS_REGION)" ]; then \
		$(MAKE) upload-aws; \
	else \
		echo "Either GCP_PROJECT_ID and GCP_REGION or AWS_ACCOUNT_ID and AWS_REGION must be set"; \
		exit 1; \
	fi

.PHONY: build-and-upload
build-and-upload:
	# @rm -rf .shared/
	# @cp -r ../shared .shared/
	$(MAKE) build
	# @rm -rf .shared/
	$(eval E2B_EXECUTE_FILE_BUCKET := $(shell grep CFNSOFTWAREBUCKET /opt/config.properties | cut -d'=' -f2))
	@echo "Using bucket: $(E2B_EXECUTE_FILE_BUCKET)"
	aws s3 cp bin/orchestrator s3://$(E2B_EXECUTE_FILE_BUCKET)/orchestrator
	aws s3 cp bin/orchestrator s3://$(E2B_EXECUTE_FILE_BUCKET)/template-manager

.PHONY: mock
mock:
	sudo TEMPLATE_BUCKET_NAME=$(TEMPLATE_BUCKET_NAME) CONSUL_TOKEN=$(CONSUL_TOKEN) NODE_ID="testclient" go run cmd/mock-sandbox/mock.go -template 5wzg6c91u51yaebviysf -build "f0370054-b669-eeee-b33b-573d5287c6ef" -alive 1 -count 2

.PHONY: mock-nbd
mock-nbd:
	sudo go run -gcflags=all="-N -l" cmd/mock-nbd/mock.go

.PHONY: mock-snapshot
mock-snapshot:
	sudo TEMPLATE_BUCKET_NAME=$(TEMPLATE_BUCKET_NAME) CONSUL_TOKEN=$(CONSUL_TOKEN) NODE_ID="testclient" go run cmd/mock-snapshot/mock.go  -template 5wzg6c91u51yaebviysf -build "f0370054-b669-4d7e-b33b-573d5287c6ef" -alive 1 -count 1

.PHONY: test
test:
	go test -v ./...

.PHONY: build-template
build-template:
	sudo -E TEMPLATE_BUCKET_NAME=$(TEMPLATE_BUCKET_NAME) \
	GOOGLE_SERVICE_ACCOUNT_BASE64=$(GOOGLE_SERVICE_ACCOUNT_BASE64) \
	DOCKER_AUTH_BASE64=$(DOCKER_AUTH_BASE64) \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) \
	GCP_DOCKER_REPOSITORY_NAME=$(GCP_DOCKER_REPOSITORY_NAME) \
	GCP_REGION=$(GCP_REGION) \
	ENVIRONMENT=local \
	go run cmd/build-template/main.go \
	-template $(TEMPLATE_ID) \
	-build $(BUILD_ID) \
	-kernel $(KERNEL_VERSION) \
	-firecracker $(FIRECRACKER_VERSION)

.PHONY: migrate
migrate:
	./upload-envs.sh /mnt/disks/fc-envs/v1 $(TEMPLATE_BUCKET_NAME)