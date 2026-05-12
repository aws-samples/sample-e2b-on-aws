# Sandbox Logs To OTel Design

Date: 2026-05-12

## Goal

Replace the current sandbox user-log write path that depends on Loki with a path that uploads through the local `otel-collector`, matching the final export pattern already used by service logs.

This design intentionally covers **write path only**. It does **not** preserve or migrate the current Loki-backed read path such as `/sandboxes/{sandboxID}/logs`.

## User-Approved Scope

- Use **方案 1**: keep `logs-collector` as the adapter layer
- Upgrade Vector from `0.34.X-alpine` to a newer version that supports an `opentelemetry` sink reliably
- Remove Loki from the sandbox log upload path
- Validate the change in the **E2B OSS dev** environment
- Do not take on the sandbox log query/read path in this change

## Current State

### Write Path Today

1. Host-side external sandbox loggers in `api`, `orchestrator`, and `template-manager` write newline-delimited JSON to `LOGS_COLLECTOR_ADDRESS`.
2. `envd` inside the sandbox VM sends JSON logs over HTTP to the address injected through MMDS.
3. `logs-collector` receives those events on `:30006`, normalizes sandbox metadata, and sends them to Loki.
4. Loki stores the logs and the API reads them back through `QueryRange`.

### Files Involved Today

- `packages/shared/pkg/logger/sandbox/logger.go`
- `packages/shared/pkg/logger/exporter.go`
- `packages/envd/internal/logs/exporter/exporter.go`
- `packages/envd/internal/logs/exporter/mmds.go`
- `packages/orchestrator/internal/sandbox/fc/mmds.go`
- `packages/orchestrator/internal/sandbox/sandbox.go`
- `packages/orchestrator/internal/sandbox/network/firewall.go`
- `nomad/origin/logs-collector.hcl`
- `nomad/origin/otel-collector.hcl`
- `nomad/origin/loki.hcl`
- `packages/api/internal/handlers/sandbox_logs.go`

## Chosen Architecture

### New Write Path

1. Keep all existing sandbox log senders unchanged:
   - host-side external sandbox loggers still POST JSON to `LOGS_COLLECTOR_ADDRESS`
   - `envd` still fetches the sink address from MMDS and POSTs JSON logs over HTTP
2. Keep `logs-collector` listening on `:30006`
3. Change `logs-collector` from a Loki sink to an OpenTelemetry-compatible sink that forwards logs to the local `otel-collector`
4. Let the local `otel-collector` export those logs to the customer log platform using the existing `otlphttp/customer` exporter

### Why This Architecture

This path minimizes risk because it avoids:

- changing the sender protocol in the host services
- changing the sender protocol in `envd`
- changing MMDS field semantics
- changing firewall assumptions for the sandbox VM

It removes Loki from the upload path while preserving the parts of the system that are already stable today.

## Version Strategy

### Vector Upgrade Requirement

Upgrade `logs-collector` from `timberio/vector:0.34.X-alpine` to **`0.44.x-alpine` or later**.

Reasoning:

- `0.43.0` is the first release that introduces the `opentelemetry` sink for emitting logs over OTLP/HTTP
- `0.44.0` includes a fix for `opentelemetry` sink input resolution

Using `0.34.X` would force a custom workaround instead of a clean adapter design.

### OTel Collector Version

Keep the existing `otel/opentelemetry-collector-contrib:0.130.0` version unchanged for this change unless testing shows an interoperability issue.

## Detailed Design

### 1. Keep Sender Behavior Unchanged

No behavior changes in:

- `packages/shared/pkg/logger/sandbox/logger.go`
- `packages/shared/pkg/logger/exporter.go`
- `packages/envd/internal/logs/exporter/exporter.go`
- `packages/envd/internal/logs/exporter/mmds.go`

This means:

- `LOGS_COLLECTOR_ADDRESS` remains `http://localhost:30006` for host-side services
- `LOGS_COLLECTOR_PUBLIC_IP` remains the address sandbox VMs use via MMDS
- firewall allowlisting for the logs collector address remains valid

### 2. Replace Loki Sink In `logs-collector`

In `nomad/origin/logs-collector.hcl`:

- upgrade the Vector image
- keep `http_server` source on `:30006`
- keep the existing remap-based field normalization
- remove the Loki sink
- add a sink that emits OTLP/HTTP to the local `otel-collector` at `http://127.0.0.1:4318/v1/logs`

The emitted log records must preserve these fields:

- `sandboxID`
- `teamID`
- `envID`
- `buildID`
- `category`
- `service`
- `traceID` when present

### 3. Map Sandbox Fields Into OTel Shape

The adapter must translate the current JSON event shape into OTel log records:

- `message` -> log body
- `timestamp` -> observed/event timestamp
- `level` -> severity text and severity number when mappable
- `service` -> `service.name`
- `sandboxID`, `teamID`, `envID`, `buildID`, `category`, `traceID` -> attributes

The exact Vector transform/sink syntax should be chosen based on the upgraded Vector version and verified by a live config test.

### 4. Add A Dedicated Sandbox Logs Pipeline In `otel-collector`

Do not route sandbox logs through the same assumptions as current service logs without review.

Add or adjust `nomad/origin/otel-collector.hcl` so that:

- sandbox logs received from `logs-collector` are accepted on OTLP/HTTP
- they are exported through `otlphttp/customer`
- they are not accidentally dropped by the current logs severity filter if sandbox logs include low-severity events that the platform still expects

Preferred approach:

- create a distinct pipeline for sandbox-originated logs if that simplifies filtering and validation

### 5. Remove Loki From The Deployment Set For This Flow

For the write-path migration itself:

- `logs-collector` should no longer depend on `loki.service.consul`
- `nomad/origin/loki.hcl` becomes unused for sandbox log upload

This design does not remove all Loki-related code references in the repository, because the read/query path is explicitly out of scope.

## Out Of Scope

- replacing `/sandboxes/{sandboxID}/logs`
- removing `lokiClient` usage from API handlers
- migrating historical Loki data
- redesigning the sandbox logger sender protocol to OTLP
- removing `logs-collector` entirely

## Rollout Plan

### Dev Rollout

1. Prepare the updated `logs-collector` HCL with the new Vector image and OTel sink
2. Prepare any required `otel-collector` pipeline changes
3. Deploy in the E2B OSS dev environment
4. Validate on one updated node first
5. Create or resume a sandbox that lands on the updated node
6. Confirm sandbox logs arrive in the customer log platform
7. Roll through the remaining dev nodes

### Production Rollout

Not part of this implementation turn. Dev validation is required first.

## Validation Plan

### Config-Level Validation

- `nomad job plan logs-collector`
- `nomad job plan otel-collector` if collector pipeline changes
- confirm the rendered Vector config contains the OTel sink, not the Loki sink
- confirm the rendered OTel config accepts the forwarded sandbox logs

### Runtime Validation In Dev

1. Confirm `logs-collector` allocs are healthy on updated nodes
2. Confirm `otel-collector` allocs are healthy on updated nodes
3. Confirm `logs-collector` no longer emits `loki.service.consul` errors
4. Create a sandbox and produce known logs from:
   - sandbox user code
   - `envd`
   - host-side external sandbox logger paths if applicable
5. Verify those logs appear in the customer log platform with expected fields:
   - `sandboxID`
   - `teamID`
   - `envID`
   - `buildID`
   - `category`
   - `service`

### Negative Validation

- stop or misconfigure the OTel sink in a test alloc and confirm the failure mode is limited to log delivery, not sandbox lifecycle
- confirm sandbox create, resume, pause, and command execution still work even if the log path is unhealthy

## Risk Assessment

### Low Risk

- sandbox create/resume logic
- MMDS metadata shape
- sandbox firewall behavior
- host-side business logic unrelated to logging

### Medium Risk

- temporary sandbox log loss during `logs-collector` rollout
- field mapping drift that makes logs harder to search in the platform
- severity filtering in `otel-collector` unexpectedly dropping sandbox logs

### Higher Risk Area

- Vector version upgrade itself, because `0.34.X` to `0.44.x` crosses several minor releases

Mitigation:

- test in dev first
- use `nomad job plan`
- roll gradually
- validate one node at a time
- keep rollback artifacts ready

## Rollback Plan

If the new write path fails in dev:

1. redeploy the previous `logs-collector` job definition with the Loki sink
2. roll back any `otel-collector` pipeline change made specifically for sandbox logs
3. verify `logs-collector` health recovers
4. verify sandbox logs resume on the old path

Rollback success criteria:

- `logs-collector` allocs healthy
- no OTel sink delivery errors
- sandbox logs visible again on the previously working path

## Open Questions Resolved

- Preserve Loki? **No**
- Preserve current read path? **No**
- Preferred implementation path? **Yes, 方案 1**
- Upgrade Vector? **Yes**

## Recommended Next Step

Write the implementation plan for:

1. `logs-collector` Vector upgrade and sink migration
2. minimal `otel-collector` pipeline change for sandbox logs
3. dev rollout and validation procedure
