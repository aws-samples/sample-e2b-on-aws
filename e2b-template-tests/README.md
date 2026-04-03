# E2B Template Tests

Test suite for E2B sandbox template creation and sandbox lifecycle on self-hosted AWS.

## Prerequisites

- E2B infrastructure deployed (all 9 steps completed)
- `/opt/config.properties` and `infra-iac/db/config.json` exist
- Python 3 with `e2b` SDK: `pip3 install e2b`
- E2B CLI: `npm install -g @e2b/cli@latest`

## Quick Start

```bash
# Run all tests
bash run-tests.sh
```

## Individual Tests

### Setup environment
```bash
source /opt/config.properties
export E2B_DOMAIN="$CFNDOMAIN"
export E2B_API_KEY=$(jq -r '.teamApiKey' ../infra-iac/db/config.json)
export E2B_ACCESS_TOKEN=$(jq -r '.accessToken' ../infra-iac/db/config.json)
```

### Template operations
```bash
# List templates
e2b template list

# Build template via Python SDK v2 (recommended)
python3 build_prod.py

# Build template via create_template.sh (legacy v1)
bash ../packages/create_template.sh

# Build template via e2b CLI (requires existing template_id in e2b.toml)
e2b template build
```

### Sandbox operations
```bash
# Create a sandbox
curl -X POST "https://api.$E2B_DOMAIN/sandboxes" \
  -H "X-API-Key: $E2B_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"templateID":"<TEMPLATE_ID>","timeout":300}'

# List sandboxes
e2b sandbox list

# Kill all sandboxes
e2b sandbox kill --all
```

## Test Files

| File | Description |
|---|---|
| `run-tests.sh` | Automated test suite (8 tests) |
| `template.py` | Python SDK v2 template definition |
| `build_dev.py` | Build template (dev alias) |
| `build_prod.py` | Build template (prod alias) |
| `e2b.Dockerfile` | Dockerfile for CLI-based builds |
| `e2b.toml` | E2B CLI configuration |
