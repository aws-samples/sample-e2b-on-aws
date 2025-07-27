BUILD := $(shell git rev-parse --short HEAD)
LDFLAGS=-ldflags "-X=main.commitSHA=$(BUILD)"

.PHONY: init
init:
	brew install protobuf

upload:
	./upload.sh $(GCP_PROJECT_ID)

build:
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))
	@if [ "$(ARCHITECTURE)" = "arm64" ]; then \
		echo "Building for arm64 architecture"; \
		CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -a -o bin/envd ${LDFLAGS}; \
	else \
		echo "Building for x86_64 architecture"; \
	    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o bin/envd ${LDFLAGS}; \
	fi

build-debug:
	$(eval ARCHITECTURE := $(shell grep "^CFNARCHITECTURE=" /opt/config.properties | cut -d= -f2 || echo "amd64"))
	@if [ "$(ARCHITECTURE)" = "arm64" ]; then \
		echo "Building for arm64 architecture"; \
		CGO_ENABLED=1 GOARCH=arm64 go build -race -gcflags=all="-N -l" -o bin/debug/envd ${LDFLAGS}; \
	else \
		echo "Building for x86_64 architecture"; \
		CGO_ENABLED=1 GOARCH=amd64 go build -race -gcflags=all="-N -l" -o bin/debug/envd ${LDFLAGS}; \
	fi

start-docker:
	DOCKER_BUILDKIT=1 docker build -t envd-debug . -f debug.Dockerfile
	docker run \
	--name envd \
	-p 49983:49983 \
	-p 2345:2345 \
	-p 9999:9999 \
	-p 8000:8000 \
	-p 8001:8001 \
	--rm \
	-i envd-debug \
	/usr/bin/envd -debug

build-and-upload:
	make build
	$(eval BUCKET_FC_ENV_PIPELINE := $(shell grep BUCKET_FC_ENV_PIPELINE /opt/config.properties | cut -d'=' -f2))
	@echo "Using bucket: $(BUCKET_FC_ENV_PIPELINE)"
	aws s3 cp bin/envd s3://$(BUCKET_FC_ENV_PIPELINE)/envd

.PHONY: generate
generate:
	go generate ./...
	cd spec && go tool buf generate --template buf.gen.yaml
	cd spec && go tool buf generate --template buf.gen.shared.yaml

.PHONY: test
test:
	go test -v ./...