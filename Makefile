ENV := $(shell cat .last_used_env || echo "not-set")
ENV_FILE := $(PWD)/.env.${ENV}

-include ${ENV_FILE}

# Set default PREFIX if not defined
PREFIX ?= e2b-
# Strip quotes and trailing spaces from PREFIX
PREFIX_CLEAN = $(strip $(subst ",,$(PREFIX)))

TERRAFORM_STATE_BUCKET ?= $(PREFIX)terraform-state-dev
OTEL_TRACING_PRINT ?= false
TEMPLATE_BUCKET_REGION ?= $(AWS_REGION)
CLIENT_ASG_MAX_SIZE ?= 0

tf_vars := TF_VAR_client_instance_type=$(CLIENT_MACHINE_TYPE) \
	TF_VAR_client_asg_desired_capacity=$(CLIENT_CLUSTER_SIZE) \
	TF_VAR_client_asg_max_size=$(CLIENT_ASG_MAX_SIZE) \
	TF_VAR_api_instance_type=$(API_MACHINE_TYPE) \
	TF_VAR_api_asg_desired_capacity=$(API_CLUSTER_SIZE) \
	TF_VAR_build_instance_type=$(BUILD_MACHINE_TYPE) \
	TF_VAR_build_asg_desired_capacity=$(BUILD_CLUSTER_SIZE) \
	TF_VAR_server_instance_type=$(SERVER_MACHINE_TYPE) \
	TF_VAR_server_asg_desired_capacity=$(SERVER_CLUSTER_SIZE) \
	TF_VAR_aws_account_id=$(AWS_ACCOUNT_ID) \
	TF_VAR_aws_region=$(AWS_REGION) \
	TF_VAR_aws_availability_zone=$(AWS_ZONE) \
	TF_VAR_domain_name=$(DOMAIN_NAME) \
	TF_VAR_additional_domains=$(ADDITIONAL_DOMAINS) \
	TF_VAR_prefix=$(PREFIX) \
	TF_VAR_terraform_state_bucket=$(TERRAFORM_STATE_BUCKET) \
	TF_VAR_otel_tracing_print=$(OTEL_TRACING_PRINT) \
	TF_VAR_environment=$(TERRAFORM_ENVIRONMENT) \
	TF_VAR_template_bucket_name=$(TEMPLATE_BUCKET_NAME) \
	TF_VAR_template_bucket_region=$(TEMPLATE_BUCKET_REGION)

# Login for AWS services
.PHONY: login-aws
login-aws:
	aws configure
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

.PHONY: init
init:
	@ printf "Initializing Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	./scripts/confirm.sh $(ENV)
	if [ "$(AWS_REGION)" = "us-east-1" ]; then \
		aws s3api create-bucket --bucket $(TERRAFORM_STATE_BUCKET) --region $(AWS_REGION) || true; \
	else \
		aws s3api create-bucket --bucket $(TERRAFORM_STATE_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION) || true; \
	fi
	terraform init -input=false -reconfigure -backend-config="bucket=${TERRAFORM_STATE_BUCKET}" -backend-config="region=${AWS_REGION}"
	# Initially, let's not create resources, we've already done that
	# $(tf_vars) terraform apply -target=module.init -target=module.buckets -auto-approve -input=false -compact-warnings
	echo "Init completed"
	# Skip building cluster disk image during init - it can be run separately
	$(MAKE) -C packages/cluster-disk-image init
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com

.PHONY: plan
plan:
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	#terraform fmt -recursive
	$(tf_vars) terraform plan -out=.tfplan.$(ENV) -compact-warnings -detailed-exitcode

.PHONY: plan-only-jobs
plan-only-jobs:
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	terraform fmt -recursive
	$(tf_vars) terraform plan -out=.tfplan.$(ENV) -compact-warnings -detailed-exitcode -target=module.nomad


.PHONY: apply
apply:
	@ printf "Applying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	./scripts/confirm.sh $(ENV)
	$(tf_vars) \
	terraform apply \
	-auto-approve \
	-input=false \
	-compact-warnings \
	-parallelism=20 \
	.tfplan.$(ENV)
	@ rm .tfplan.$(ENV)

.PHONY: plan-without-jobs
plan-without-jobs:
	@ printf "Planning Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(eval TARGET := $(shell cat main.tf | grep "^module" | awk '{print $$2}' | tr ' ' '\n' | grep -v -e "nomad" | awk '{print "-target=module." $$0 ""}' | xargs))
	$(tf_vars) \
	terraform plan \
	-out=.tfplan.$(ENV) \
	-input=false \
	-compact-warnings \
	-parallelism=20 \
	$(TARGET)

.PHONY: destroy
destroy:
	@ printf "Destroying Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	./scripts/confirm.sh $(ENV)
	$(tf_vars) \
	terraform destroy \
	-compact-warnings \
	-parallelism=20 \
	$$(terraform state list | grep module | cut -d'.' -f1,2 | grep -v -e "buckets" | uniq | awk '{print "-target=" $$0 ""}' | xargs)

.PHONY: version
version:
	./scripts/increment-version.sh

.PHONY: build-and-upload
build-and-upload:
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/api build-and-upload || true
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/client-proxy build-and-upload || true
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/docker-reverse-proxy build-and-upload || true
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/orchestrator build-and-upload || true
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/template-manager build-and-upload || true
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/envd build-and-upload || true
build/%:
	$(MAKE) -C packages/$(notdir $@) build
build-and-upload/%:
	AWS_REGION=us-east-1 \
	GCP_PROJECT_ID=$(GCP_PROJECT_ID) GCP_REGION=$(GCP_REGION) AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) $(MAKE) -C packages/$(notdir $@) build-and-upload

.PHONY: check-env
check-env:
	@echo "Checking environment configuration for '$(ENV)'..."
	@if [ ! -f "$(ENV_FILE)" ]; then \
		echo "❌ Error: Environment file $(ENV_FILE) not found"; \
		echo "Available environments:"; \
		ls -1 .env.* | grep -v template; \
		echo "To switch environment: make ENV=<env-name> switch-env"; \
		exit 1; \
	fi
	@echo "✅ Using environment file: $(ENV_FILE)"
	@echo "   - PREFIX: $(PREFIX)"
	@echo "   - AWS_REGION: $(AWS_REGION)"
	@echo "   - AWS_ACCOUNT_ID: $(AWS_ACCOUNT_ID)"

.PHONY: check-aws
check-aws: check-env
	@echo "Checking AWS CLI configuration..."
	@aws sts get-caller-identity >/dev/null || { echo "❌ Error: AWS CLI is not configured properly. Please run 'aws configure' first."; exit 1; }
	@echo "✅ AWS CLI is properly configured with region $(AWS_REGION)"

.PHONY: check-gsutil
check-gsutil: check-env
	@echo "Checking gsutil configuration..."
	@command -v gsutil >/dev/null 2>&1 || { echo "❌ Error: gsutil is not installed. Please install the Google Cloud SDK."; exit 1; }
	@gsutil ls gs://e2b-prod-public-builds/ >/dev/null 2>&1 || { echo "❌ Error: gsutil cannot access GCS buckets. Please run 'gcloud auth login' first."; exit 1; }
	@echo "✅ gsutil is properly configured and can access public builds"

.PHONY: create-buckets
create-buckets: check-aws
	@echo "Creating required S3 buckets manually in $(AWS_REGION) with prefix $(PREFIX_CLEAN)..."
	
	# Define bucket names from the environment file using PREFIX_CLEAN
	$(eval ENV_BUCKET = $(PREFIX_CLEAN)fc-env-pipeline)
	$(eval KERNELS_BUCKET = $(PREFIX_CLEAN)fc-kernels)
	$(eval VERSIONS_BUCKET = $(PREFIX_CLEAN)fc-versions)
	
	@echo "Creating the following buckets:"
	@echo " - Environment Pipeline: $(ENV_BUCKET)"
	@echo " - FC Kernels: $(KERNELS_BUCKET)"
	@echo " - FC Versions: $(VERSIONS_BUCKET)"
	
	@# Create buckets with proper error handling based on region
	@if [ "$(AWS_REGION)" = "us-east-1" ]; then \
		echo "Creating buckets in us-east-1..."; \
		aws s3api create-bucket --bucket $(KERNELS_BUCKET) --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(KERNELS_BUCKET) already exists or couldn't be created"; \
		aws s3api create-bucket --bucket $(VERSIONS_BUCKET) --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(VERSIONS_BUCKET) already exists or couldn't be created"; \
		aws s3api create-bucket --bucket $(ENV_BUCKET) --region $(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(ENV_BUCKET) already exists or couldn't be created"; \
	else \
		echo "Creating buckets in $(AWS_REGION)..."; \
		aws s3api create-bucket --bucket $(KERNELS_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(KERNELS_BUCKET) already exists or couldn't be created"; \
		aws s3api create-bucket --bucket $(VERSIONS_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(VERSIONS_BUCKET) already exists or couldn't be created"; \
		aws s3api create-bucket --bucket $(ENV_BUCKET) --region $(AWS_REGION) --create-bucket-configuration LocationConstraint=$(AWS_REGION) 2>/dev/null || echo "⚠️ Note: Bucket $(ENV_BUCKET) already exists or couldn't be created"; \
	fi
	
	@echo "✅ Bucket creation completed."

.PHONY: copy-public-builds
copy-public-builds: create-buckets check-gsutil
	@echo "=== Copying public builds from GCS to AWS S3 ==="
	@echo "Environment: $(ENV)"
	@echo "PREFIX (raw): $(PREFIX)"
	@echo "PREFIX (clean): $(PREFIX_CLEAN)"
	@echo "AWS_REGION: $(AWS_REGION)"
	
	@echo "Creating temporary directories..."
	@rm -rf ./tmp/public-builds
	@mkdir -p ./tmp/public-builds/envd-v0.0.1
	@mkdir -p ./tmp/public-builds/kernels
	@mkdir -p ./tmp/public-builds/firecrackers
	
	# Define bucket names from the environment file using PREFIX_CLEAN
	$(eval ENV_BUCKET = $(PREFIX_CLEAN)fc-env-pipeline)
	$(eval KERNELS_BUCKET = $(PREFIX_CLEAN)fc-kernels)
	$(eval VERSIONS_BUCKET = $(PREFIX_CLEAN)fc-versions)
	
	@echo "Using the following bucket names (from $(ENV_FILE)):"
	@echo " - Environment Pipeline: $(ENV_BUCKET)"
	@echo " - FC Kernels: $(KERNELS_BUCKET)"
	@echo " - FC Versions: $(VERSIONS_BUCKET)"
	
	# GCS access already verified in check-gsutil target
	
	@echo "Validating that AWS S3 buckets exist..."
	aws s3api head-bucket --bucket $(ENV_BUCKET) --region $(AWS_REGION) || { echo "❌ Error: Bucket $(ENV_BUCKET) doesn't exist or not accessible"; exit 1; }
	aws s3api head-bucket --bucket $(KERNELS_BUCKET) --region $(AWS_REGION) || { echo "❌ Error: Bucket $(KERNELS_BUCKET) doesn't exist or not accessible"; exit 1; }
	aws s3api head-bucket --bucket $(VERSIONS_BUCKET) --region $(AWS_REGION) || { echo "❌ Error: Bucket $(VERSIONS_BUCKET) doesn't exist or not accessible"; exit 1; }
	
	@echo "Downloading from GCS to local storage..."
	@echo "1. Checking and downloading envd builds..."
	if gsutil -q ls gs://e2b-prod-public-builds/envd-v0.0.1 >/dev/null 2>&1; then \
		gsutil -m cp -r gs://e2b-prod-public-builds/envd-v0.0.1 ./tmp/public-builds || { echo "❌ Error downloading envd builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: envd-v0.0.1 directory not found, skipping"; \
	fi
	
	@echo "2. Checking and downloading kernel builds..."
	if gsutil -q ls gs://e2b-prod-public-builds/kernels/ >/dev/null 2>&1; then \
		gsutil -m cp -r gs://e2b-prod-public-builds/kernels/* ./tmp/public-builds/kernels/ || { echo "❌ Error downloading kernel builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: kernels directory not found or empty, skipping"; \
	fi
	
	@echo "3. Checking and downloading firecracker builds..."
	if gsutil -q ls gs://e2b-prod-public-builds/firecrackers/ >/dev/null 2>&1; then \
		gsutil -m cp -r gs://e2b-prod-public-builds/firecrackers/* ./tmp/public-builds/firecrackers/ || { echo "❌ Error downloading firecracker builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: firecrackers directory not found or empty, skipping"; \
	fi
	
	@echo "Uploading from local storage to AWS S3..."
	@echo "1. Uploading envd builds..."
	if [ -n "$(ls -A ./tmp/public-builds/envd-v0.0.1 2>/dev/null)" ]; then \
		aws s3 cp ./tmp/public-builds/envd-v0.0.1/envd-v0.0.1 s3://$(ENV_BUCKET)/envd-v0.0.1 --region $(AWS_REGION) || { echo "❌ Error uploading envd builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: No envd builds to upload"; \
	fi
	
	@echo "2. Uploading kernel builds..."
	if [ -n "$(ls -A ./tmp/public-builds/kernels/ 2>/dev/null)" ]; then \
		aws s3 sync ./tmp/public-builds/kernels/ s3://$(KERNELS_BUCKET)/ --region $(AWS_REGION) || { echo "❌ Error uploading kernel builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: No kernel builds to upload"; \
	fi
	
	@echo "3. Uploading firecracker builds..."
	if [ -n "$(ls -A ./tmp/public-builds/firecrackers/ 2>/dev/null)" ]; then \
		aws s3 sync ./tmp/public-builds/firecrackers/ s3://$(VERSIONS_BUCKET)/ --region $(AWS_REGION) || { echo "❌ Error uploading firecracker builds"; exit 1; }; \
	else \
		echo "⚠️ Warning: No firecracker builds to upload"; \
	fi
	
	@echo "Verifying uploads..."
	@echo "1. Checking envd builds..."
	aws s3 ls --region $(AWS_REGION) s3://$(ENV_BUCKET)/envd-v0.0.1/ 2>/dev/null | head -5 || echo "⚠️ No envd builds found in destination bucket"
	
	@echo "2. Checking kernel builds..."
	aws s3 ls --region $(AWS_REGION) s3://$(KERNELS_BUCKET)/ 2>/dev/null | head -5 || echo "⚠️ No kernel builds found in destination bucket"
	
	@echo "3. Checking firecracker builds..."
	aws s3 ls --region $(AWS_REGION) s3://$(VERSIONS_BUCKET)/ 2>/dev/null | head -5 || echo "⚠️ No firecracker builds found in destination bucket"
	
	@echo "Cleaning up local files..."
	#rm -rf ./tmp/public-builds
	@echo "✅ Copy operation complete. Successfully copied public builds to AWS S3 buckets."

.PHONY: migrate
migrate:
	$(MAKE) -C packages/shared migrate

.PHONY: switch-env
switch-env:
	@ touch .last_used_env
	@ printf "Switching from `tput setaf 1``tput bold`$(shell cat .last_used_env)`tput sgr0` to `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	@ echo $(ENV) > .last_used_env
	@ . ${ENV_FILE}
	terraform init -input=false -upgrade -reconfigure -backend-config="bucket=${TERRAFORM_STATE_BUCKET}" -backend-config="region=${AWS_REGION}"

# Shortcut to importing resources into Terraform state (e.g. after creating resources manually or switching between different branches for the same environment)
.PHONY: import
import:
	@ printf "Importing resources for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	./scripts/confirm.sh $(ENV)
	$(tf_vars) terraform import $(TARGET) $(ID)

.PHONY: setup-ssh
setup-ssh:
	@ printf "Setting up SSH for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n"
	@ aws ec2 describe-instances --region $(AWS_REGION) --query "Reservations[*].Instances[*].[InstanceId,Tags[?Key=='Name'].Value|[0],State.Name,PrivateIpAddress,PublicIpAddress]" --output table
	@ printf "SSH setup complete. Use your AWS key pair to connect to the instances.\n"

.PHONY: test
test:
	$(MAKE) -C packages/api test
	$(MAKE) -C packages/client-proxy test
	$(MAKE) -C packages/docker-reverse-proxy test
	$(MAKE) -C packages/envd test
	$(MAKE) -C packages/orchestrator test
	$(MAKE) -C packages/shared test
	$(MAKE) -C packages/template-manager test
	
.PHONY: build-aws-ami
build-aws-ami:
	@ printf "Building AWS AMI for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	$(MAKE) -C packages/cluster-disk-image build


# $(MAKE) -C terraform/grafana init does not work b/c of the -include ${ENV_FILE} in the Makefile
# so we need to call the Makefile directly
# && cd - || cd - is used to handle the case where the command fails, we still want to cd -
.PHONY: grafana-init
grafana-init:
	@ printf "Initializing Grafana Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	cd terraform/grafana && make init && cd - || cd -

.PHONY: grafana-plan
grafana-plan:
	@ printf "Planning Grafana Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	cd terraform/grafana && make plan && cd - || cd -

.PHONY: grafana-apply
grafana-apply:
	@ printf "Applying Grafana Terraform for env: `tput setaf 2``tput bold`$(ENV)`tput sgr0`\n\n"
	cd terraform/grafana && make apply && cd - || cd -

.PHONY: e2b:build:dev
e2b:build:dev:
	cd test && python build_dev.py

.PHONY: e2b:build:prod
e2b:build:prod:
	cd test && python build_prod.py
