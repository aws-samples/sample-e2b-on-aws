# E2B Tests

Automated test suite for self-hosted E2B on AWS.

## Structure

```
tests/
├── run-tests.sh              # Test runner (all or by category)
├── sdk/
│   └── test_sdk.py           # Python SDK full test (10 tests)
├── template/
│   ├── template.py           # Template definition (SDK v2)
│   ├── build_dev.py          # Build dev template
│   └── build_prod.py         # Build prod template
└── dockerfiles/
    ├── e2b.Dockerfile         # Basic Ubuntu + Python
    ├── e2b.Dockerfile.BrowserUse
    ├── e2b.Dockerfile.Desktop
    ├── e2b.Dockerfile.code_interpreter
    └── e2b.Dockerfile.s3fs
```

## Quick Start

```bash
# Run all tests
bash tests/run-tests.sh

# Run specific category
bash tests/run-tests.sh health      # API health only
bash tests/run-tests.sh sdk         # Python SDK (10 tests)
bash tests/run-tests.sh template    # Template build (SDK v2)
bash tests/run-tests.sh legacy      # Template build (create_template.sh)
bash tests/run-tests.sh cli         # E2B CLI operations
```

## SDK Tests (10 tests)

| # | Test | What it verifies |
|---|---|---|
| 1 | Template Build | SDK v2 template creation |
| 2 | Sandbox Create | Sandbox lifecycle start |
| 3 | Commands | echo, multi-line, exit codes |
| 4 | File I/O | Write, read, list directory |
| 5 | File URLs | Download/upload URL generation |
| 6 | Background Process | Start, verify, kill process |
| 7 | Env Variables | Custom envs passed to sandbox |
| 8 | Timeout & Metadata | Metadata read, timeout extend |
| 9 | Sandbox List | Paginated sandbox listing |
| 10 | Kill & Cleanup | Kill sandbox, verify removal |

## Prerequisites

```bash
pip3 install e2b
npm install -g @e2b/cli@latest
```

## Custom Template Dockerfiles

Build a custom template from any Dockerfile:

```bash
bash packages/create_template.sh --docker-file tests/dockerfiles/e2b.Dockerfile.code_interpreter
```
