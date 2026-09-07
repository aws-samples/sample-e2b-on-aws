# snapshot-retention is built on the bastion like the other binaries and
# published next to them, where nomad/origin/snapshot-retention.hcl fetches it.
# tools/build-and-upload.sh exports AWS_BUCKET_PREFIX and AWS_PROFILE.

BIN := bin/snapshot-retention

.PHONY: build
build:
	CGO_ENABLED=0 go build -o $(BIN) .

.PHONY: test
test:
	go test ./...

.PHONY: upload
upload:
	$(eval COMMIT_SHA := $(shell git rev-parse --short HEAD))
	chmod +x $(BIN)
	aws s3 cp $(BIN) "s3://${AWS_BUCKET_PREFIX}fc-env-pipeline/snapshot-retention" --profile ${AWS_PROFILE} --cache-control "no-cache, max-age=0"
	aws s3 cp $(BIN) "s3://${AWS_BUCKET_PREFIX}fc-env-pipeline/snapshot-retention.$(COMMIT_SHA)" --profile ${AWS_PROFILE} --cache-control "no-cache, max-age=0"

.PHONY: build-and-upload
build-and-upload: build upload
