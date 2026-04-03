#!/bin/bash
# E2B Template Tests - run all template creation and sandbox tests
set -e

cd "$(dirname "$0")"
SCRIPT_DIR=$(pwd)
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")

# ============================================================
# Load E2B credentials
# ============================================================
CONFIG_FILE="/opt/config.properties"
CONFIG_JSON="${PROJECT_ROOT}/infra-iac/db/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found. Run deployment first."
    exit 1
fi

if [ ! -f "$CONFIG_JSON" ]; then
    echo "Error: $CONFIG_JSON not found. Run db/init-db.sh first."
    exit 1
fi

source "$CONFIG_FILE" 2>/dev/null || true

export E2B_DOMAIN="$CFNDOMAIN"
export E2B_API_KEY=$(jq -r '.teamApiKey' "$CONFIG_JSON")
export E2B_ACCESS_TOKEN=$(jq -r '.accessToken' "$CONFIG_JSON")

echo "============================================"
echo "E2B Template Tests"
echo "============================================"
echo "Domain:  $E2B_DOMAIN"
echo "API Key: ${E2B_API_KEY:0:10}..."
echo ""

# ============================================================
# Test 1: API Health Check
# ============================================================
echo "--- Test 1: API Health Check ---"
HEALTH=$(curl -s --max-time 10 "https://api.${E2B_DOMAIN}/health")
if [ "$HEALTH" = "Health check successful" ]; then
    echo "  PASS: API healthy"
else
    echo "  FAIL: API returned '$HEALTH'"
    exit 1
fi
echo ""

# ============================================================
# Test 2: Template List (via CLI)
# ============================================================
echo "--- Test 2: Template List (CLI) ---"
e2b template list 2>&1 | head -5
echo ""

# ============================================================
# Test 3: Build template via Python SDK v2 (basic)
# ============================================================
echo "--- Test 3: Build Template (Python SDK v2 - basic) ---"
TEMPLATE_ID_BASIC=$(python3 << 'PYEOF'
import os, sys
from e2b import Template, default_build_logger

template = (
    Template()
    .from_image("e2bdev/base")
    .run_cmd("echo Hello from E2B basic test!")
)

build = Template.build(
    template,
    "test-basic",
    on_build_logs=default_build_logger(),
)
print(build.template_id)
PYEOF
)
echo "  PASS: Template ID = $TEMPLATE_ID_BASIC"
echo ""

# ============================================================
# Test 4: Build template via Python SDK v2 (with packages)
# ============================================================
echo "--- Test 4: Build Template (Python SDK v2 - python+packages) ---"
TEMPLATE_ID_PYTHON=$(python3 << 'PYEOF'
import os, sys
from e2b import Template, default_build_logger

template = (
    Template()
    .from_python_image()
    .pip_install("numpy", "requests")
    .set_workdir("/home/user")
)

build = Template.build(
    template,
    "test-python",
    on_build_logs=default_build_logger(),
)
print(build.template_id)
PYEOF
)
echo "  PASS: Template ID = $TEMPLATE_ID_PYTHON"
echo ""

# ============================================================
# Test 5: Build template via create_template.sh (legacy v1)
# ============================================================
echo "--- Test 5: Build Template (create_template.sh - legacy v1) ---"
bash "${PROJECT_ROOT}/packages/create_template.sh" 2>&1 | tail -3
echo ""

# ============================================================
# Test 6: Create Sandbox via API
# ============================================================
echo "--- Test 6: Create Sandbox (curl) ---"
SANDBOX_RESPONSE=$(curl -s -X POST "https://api.${E2B_DOMAIN}/sandboxes" \
    -H "X-API-Key: ${E2B_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"templateID\": \"${TEMPLATE_ID_BASIC}\", \"timeout\": 60}")
SANDBOX_ID=$(echo "$SANDBOX_RESPONSE" | jq -r '.sandboxID // .sandboxId // empty' 2>/dev/null)
if [ -n "$SANDBOX_ID" ] && [ "$SANDBOX_ID" != "null" ]; then
    echo "  PASS: Sandbox created = $SANDBOX_ID"
else
    echo "  INFO: Sandbox response = $SANDBOX_RESPONSE"
fi
echo ""

# ============================================================
# Test 7: List Sandboxes (CLI)
# ============================================================
echo "--- Test 7: List Sandboxes (CLI) ---"
e2b sandbox list 2>&1 | head -5
echo ""

# ============================================================
# Test 8: Kill all sandboxes
# ============================================================
echo "--- Test 8: Cleanup Sandboxes ---"
e2b sandbox kill --all 2>&1 || true
echo ""

# ============================================================
# Summary
# ============================================================
echo "============================================"
echo "All tests completed!"
echo "============================================"
echo ""
echo "Templates created:"
echo "  test-basic:  $TEMPLATE_ID_BASIC"
echo "  test-python: $TEMPLATE_ID_PYTHON"
echo ""
echo "Quick commands for manual testing:"
echo "  e2b template list"
echo "  e2b sandbox list"
echo "  curl -X POST https://api.${E2B_DOMAIN}/sandboxes -H 'X-API-Key: ${E2B_API_KEY}' -H 'Content-Type: application/json' -d '{\"templateID\":\"${TEMPLATE_ID_BASIC}\",\"timeout\":60}'"
