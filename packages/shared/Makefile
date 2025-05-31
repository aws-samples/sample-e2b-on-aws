ENV := $(shell cat ../../.last_used_env || echo "not-set")
-include ../../.env.${ENV}

.PHONY: generate-fc
generate-fc:
	cd pkg/fc && swagger generate client -f firecracker.yml -A firecracker

.PHONY: generate-models
generate-models:
	@echo "Generating models..."
	@find pkg/models/* -not -path "pkg/models/clickhouse*" -delete
	@go generate ./pkg/generate_models.go
	@echo "Done"

.PHONY: prep-cluster
prep-cluster:
	@echo "Setting up AWS configuration..."
	@mkdir -p ~/.e2b
	@echo '{"email":"admin@example.com","teamId":"00000000-0000-0000-0000-000000000000","accessToken":"e2b_access_token","teamApiKey":"e2b_team_api_key","cloud":"aws","provider":"aws","region":"us-east-1"}' > ~/.e2b/config.json
	@echo "Seeding database..."
	@export AWS_ENABLED=true
	@export E2B_CLOUD=aws
	@export E2B_REGION=us-east-1
	@export DB_HOST=database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com
	@if [ -z "$(POSTGRES_CONNECTION_STRING)" ]; then \
		export POSTGRES_CONNECTION_STRING="postgresql://postgres:Longyuan123@database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com:5432/postgres"; \
	fi
	@echo $(POSTGRES_CONNECTION_STRING)
	@E2B_CLOUD=aws AWS_ENABLED=true E2B_REGION=us-east-1 POSTGRES_CONNECTION_STRING=$(POSTGRES_CONNECTION_STRING) DB_HOST=database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com DB_USER=postgres DB_PASSWORD=Longyuan123 DB_NAME=postgres DB_PORT=5432 ./scripts/aws-seed.sh
	@echo "Building base template for AWS..."
	@E2B_DOMAIN=$(DOMAIN_NAME) E2B_CLOUD=aws E2B_REGION=us-east-1 e2b tpl build -p scripts
	@echo "Done"

.PHONY: migrate
migrate:
	@echo "Generating migrations..."
	@cat ./migrations/* > ./migration.sql
	@echo "Applying migration"
	@if [ -z "$(POSTGRES_CONNECTION_STRING)" ]; then \
		echo "Error: POSTGRES_CONNECTION_STRING is not set"; \
		exit 1; \
	fi
	@echo "Using direct PSQL approach instead of Go script to avoid dependency issues"
	@echo "Using connection string: $(POSTGRES_CONNECTION_STRING)"
	@cat ./migration.sql | PGPASSWORD=$(shell echo "$(POSTGRES_CONNECTION_STRING)" | sed -n 's/.*password=\([^@]*\).*/\1/p') /usr/bin/psql -h $(shell echo "$(POSTGRES_CONNECTION_STRING)" | sed -n 's/.*@\([^:]*\).*/\1/p') -U postgres -d postgres
	@rm ./migration.sql
	@echo "Done"

.PHONY: test
test:
	go test -v ./pkg/...

.PHONY: prep-aws
prep-aws:
	@echo "Creating AWS configuration..."
	@mkdir -p ~/.e2b
	@echo '{"email":"admin@example.com","teamId":"00000000-0000-0000-0000-000000000000","accessToken":"e2b_access_token","teamApiKey":"e2b_team_api_key","cloud":"aws","provider":"aws","region":"us-east-1"}' > ~/.e2b/config.json
	@echo "Created AWS config file"
	
	@echo "Setting AWS environment variables"
	@export AWS_ENABLED=true
	@export E2B_CLOUD=aws
	@export E2B_REGION=us-east-1
	@export POSTGRES_CONNECTION_STRING="postgresql://postgres:Longyuan123@database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com:5432/postgres"
	@export DB_HOST=database-e2b.cluster-cqjwsuyea136.us-east-1.rds.amazonaws.com
	@export DB_USER=postgres
	@export DB_PASSWORD=Longyuan123
	@export DB_NAME=postgres
	@export DB_PORT=5432
	
	@echo "Running migrations first"
	@make migrate
	
	@echo "Seeding database for AWS"
	@E2B_CLOUD=aws AWS_ENABLED=true ./scripts/aws-seed.sh
	
	@echo "Building base template for AWS"
	@E2B_CLOUD=aws E2B_REGION=us-east-1 e2b tpl build -p scripts || echo "Template build skipped - please run manually with AWS credentials"
	
	@echo "AWS configuration complete"
