ENV := $(shell cat ../../.last_used_env || echo "not-set")
-include ../../.env.${ENV}

init:
	packer init -upgrade .

# Detect system architecture
ARCH := $(arch)
ifeq ($(ARCH),x86_64)
  ARCHITECTURE := x86_64
  AWS_INSTANCE_TYPE_DEFAULT := t3.xlarge
else ifeq ($(ARCH),aarch64)
  ARCHITECTURE := arm64
  AWS_INSTANCE_TYPE_DEFAULT := t4g.xlarge
else
  $(error Unsupported architecture: $(ARCH))
endif

# Use architecture-specific instance type if not specified
CLIENT_MACHINE_TYPE ?= $(AWS_INSTANCE_TYPE_DEFAULT)

build:
	if [ -n "$(AWS_REGION)" ]; then \
		PACKER_LOG=1 packer build -only=amazon-ebs.orch -var "aws_region=$(AWS_REGION)" -var "aws_instance_type=$(CLIENT_MACHINE_TYPE)" .; \
	else \
		echo "Error: AWS_REGION must be set"; \
		exit 1; \
	fi

format:
	packer fmt .
