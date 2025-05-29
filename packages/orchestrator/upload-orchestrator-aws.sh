#!/bin/bash

set -euo pipefail

AWS_BUCKET_NAME=$1
AWS_REGION=${2:-us-east-1}

chmod +x bin/orchestrator

aws s3 cp bin/orchestrator "s3://${AWS_BUCKET_NAME}/orchestrator" \
  --region ${AWS_REGION} \
  --cache-control "no-cache, max-age=0"
