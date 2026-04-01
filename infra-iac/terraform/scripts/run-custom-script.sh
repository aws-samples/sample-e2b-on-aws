#!/bin/bash
# Shared script: download and execute a custom startup script
# Usage: run-custom-script.sh <url>
# Supports s3:// and https:// URLs. Failures are logged but do not exit non-zero.

CUSTOM_SCRIPT_URL="$1"

if [ -z "$CUSTOM_SCRIPT_URL" ]; then
  exit 0
fi

echo "=== Custom Script Execution ==="
CUSTOM_SCRIPT_PATH="/tmp/custom-startup-script.sh"

if [[ "$CUSTOM_SCRIPT_URL" == s3://* ]]; then
  aws s3 cp "$CUSTOM_SCRIPT_URL" "$CUSTOM_SCRIPT_PATH"
else
  curl -fsSL "$CUSTOM_SCRIPT_URL" -o "$CUSTOM_SCRIPT_PATH"
fi

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to download custom script from $CUSTOM_SCRIPT_URL"
  exit 0
fi

chmod +x "$CUSTOM_SCRIPT_PATH"
echo "Executing custom script..."
bash "$CUSTOM_SCRIPT_PATH"
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "WARNING: Custom script exited with code $EXIT_CODE"
else
  echo "Custom script execution completed successfully."
fi
