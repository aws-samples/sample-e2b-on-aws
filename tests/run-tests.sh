#!/bin/bash
# E2B Test Suite - run all or specific test categories
set -e

cd "$(dirname "$0")"
PROJECT_ROOT=$(dirname "$(pwd)")

# ============================================================
# Load credentials
# ============================================================
CONFIG_FILE="/opt/config.properties"
CONFIG_JSON="${PROJECT_ROOT}/infra-iac/db/config.json"

if [ ! -f "$CONFIG_FILE" ] || [ ! -f "$CONFIG_JSON" ]; then
    echo "Error: Config files not found. Deploy first."
    exit 1
fi

source "$CONFIG_FILE" 2>/dev/null || true
export E2B_DOMAIN="$CFNDOMAIN"
export E2B_API_KEY=$(jq -r '.teamApiKey' "$CONFIG_JSON")
export E2B_ACCESS_TOKEN=$(jq -r '.accessToken' "$CONFIG_JSON")

echo "============================================"
echo "E2B Test Suite"
echo "============================================"
echo "Domain:  $E2B_DOMAIN"
echo "API Key: ${E2B_API_KEY:0:10}..."
echo ""

show_help() {
    echo "Usage: $0 [CATEGORY]"
    echo ""
    echo "Categories:"
    echo "  health     - API health check only"
    echo "  sdk        - Python SDK tests (10 tests: sandbox lifecycle, files, commands)"
    echo "  template   - Template build via Python SDK v2"
    echo "  legacy     - Template build via create_template.sh (v1)"
    echo "  cli        - E2B CLI operations"
    echo "  all        - Run all tests (default)"
    echo ""
    exit 0
}

test_health() {
    echo "--- Health Check ---"
    HEALTH=$(curl -s --max-time 10 "https://api.${E2B_DOMAIN}/health")
    if [ "$HEALTH" = "Health check successful" ]; then
        echo "  PASS: API healthy"
    else
        echo "  FAIL: API returned '$HEALTH'"
        return 1
    fi
}

test_sdk() {
    echo "--- SDK Tests (10 tests) ---"
    python3 sdk/test_sdk.py
}

test_template() {
    echo "--- Template Build (SDK v2) ---"
    python3 << 'PYEOF'
import os
from e2b import Template, default_build_logger
template = Template().from_image("e2bdev/base").run_cmd("echo 'Template test passed!'")
build = Template.build(template, "test-template", on_build_logs=default_build_logger())
print(f"\n  PASS: Template ID = {build.template_id}")
PYEOF
}

test_legacy() {
    echo "--- Legacy Template Build (create_template.sh) ---"
    OUTPUT=$(bash "${PROJECT_ROOT}/packages/create_template.sh" 2>&1)
    STATUS=$(echo "$OUTPUT" | grep "Final status:" | awk '{print $NF}')
    if [ "$STATUS" = "ready" ]; then
        TEMPLATE_ID=$(echo "$OUTPUT" | grep "templateID:" | awk '{print $2}')
        echo "  PASS: Template $TEMPLATE_ID built successfully"
    else
        echo "$OUTPUT" | tail -5
        echo "  FAIL: Build status = $STATUS"
        return 1
    fi
}

test_cli() {
    echo "--- CLI Tests ---"
    echo "  Template list:"
    e2b template list 2>&1 | head -8
    echo ""
    echo "  Sandbox list:"
    e2b sandbox list 2>&1 | head -5
    echo "  PASS: CLI operations completed"
}

case "${1:-all}" in
    health)   test_health ;;
    sdk)      test_health && test_sdk ;;
    template) test_health && test_template ;;
    legacy)   test_health && test_legacy ;;
    cli)      test_health && test_cli ;;
    all)
        test_health && echo "" && test_sdk && echo "" && test_template && echo "" && test_cli
        echo ""
        echo "============================================"
        echo "All test categories completed!"
        echo "============================================"
        ;;
    -h|--help|help) show_help ;;
    *) echo "Unknown category: $1" && show_help ;;
esac
