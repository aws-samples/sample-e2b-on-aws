IMAGE := e2b-orchestration/api


openapi := ../../spec/openapi.yml
codegen := go tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen
expectedMigration := $(shell ./../../scripts/get-latest-migration.sh)

.PHONY: generate
generate:
	$(codegen) -old-config-style -generate gin --package api $(openapi) > internal/api/api.gen.go
	$(codegen) -old-config-style -generate types --package api $(openapi) > internal/api/types.gen.go
	$(codegen) -old-config-style -generate spec --package api $(openapi) > internal/api/spec.gen.go


.PHONY: build
build:
	# Allow for passing commit sha directly for docker builds
	$(eval COMMIT_SHA ?= $(shell git rev-parse --short HEAD))
	$(eval EXPECTED_MIGRATION_TIMESTAMP ?= $(expectedMigration))
	CGO_ENABLED=0 go build -o bin/api -ldflags "-X=main.commitSHA=$(COMMIT_SHA) -X=main.expectedMigrationTimestamp=$(EXPECTED_MIGRATION_TIMESTAMP)" .

.PHONY: build-debug
build-debug:
	$(eval COMMIT_SHA ?= $(shell git rev-parse --short HEAD))
	$(eval EXPECTED_MIGRATION_TIMESTAMP ?= $(expectedMigration))
	CGO_ENABLED=1 go build -race -gcflags=all="-N -l" -o bin/api -ldflags "-X=main.commitSHA=$(COMMIT_SHA) -X=main.expectedMigrationTimestamp=$(EXPECTED_MIGRATION_TIMESTAMP)" .

.PHONY: run
run:
	make build-debug
	POSTGRES_CONNECTION_STRING=$(POSTGRES_CONNECTION_STRING) \
	SUPABASE_JWT_SECRETS=$(SUPABASE_JWT_SECRETS) \
	GOTRACEBACK=crash \
	GODEBUG=madvdontneed=1 \
	TEMPLATE_BUCKET_NAME=$(TEMPLATE_BUCKET_NAME) \
	SANDBOX_ACCESS_TOKEN_HASH_SEED=$(SANDBOX_ACCESS_TOKEN_HASH_SEED) \
	ENVIRONMENT=$(ENVIRONMENT) \
	ORCHESTRATOR_PORT=5008 \
	./bin/api --port 3000

# Run the API using air
.PHONY: dev
dev:
	go tool air

# You run the parametrized command like this:
# make metric=heap interval=90 profiler
.PHONY: profiler
profiler:
	go tool pprof -http :9991 http://localhost:3000/debug/pprof/$(metric)?seconds=$(interval)\&timeout=120

.PHONY: build-and-upload
build-and-upload:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	$(eval EXPECTED_MIGRATION_TIMESTAMP := $(expectedMigration))
	@rm -rf .shared/ .db/
	@cp -r ../shared .shared/
	@cp -r ../db .db/
	@docker buildx install # sets up the buildx as default docker builder (otherwise the command below won't work)
	@docker build --platform linux/amd64 --tag "$(GCP_REGION)-docker.pkg.dev/$(GCP_PROJECT_ID)/$(IMAGE)" --push --build-arg COMMIT_SHA="$(COMMIT_SHA)" --build-arg EXPECTED_MIGRATION_TIMESTAMP="$(EXPECTED_MIGRATION_TIMESTAMP)" .
	@rm -rf .shared/
	@rm -rf .db/

.PHONY: test
test:
	go test -v ./...

.PHONY: build-and-upload-aws
build-and-upload-aws:
	$(eval AWS_ACCOUNT_ID := $(shell grep "^account_id=" /opt/config.properties | cut -d= -f2))
	$(eval AWS_REGION := $(shell grep "^AWSREGION=" /opt/config.properties | cut -d= -f2))
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))
	
	@rm -rf .shared/ .db/
	@cp -r ../shared .shared/
	@cp -r ../db .db/
	@docker buildx install || true # sets up the buildx as default docker builder
	# Create ECR repository if it doesn't exist
	@aws ecr describe-repositories --repository-names $(IMAGE) || aws ecr create-repository --repository-name $(IMAGE)
	# Login to ECR
	@aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	# Build and push the image
	@echo "Building for architecture: $(ARCHITECTURE)"
	@docker build --platform linux/$(ARCHITECTURE) --tag "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest" .
	@docker push "$(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/$(IMAGE):latest"
	@rm -rf .shared/