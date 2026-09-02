# Design: graceful scale-in for the client pool

Status: proposed. Revised 2026-09-02 after a two-model cross-review (Claude and
Codex, each checking the other's findings against the code); the revision notes
at the end list what changed and why. Nothing in this document is implemented
yet.

## Goal

Terminating a client node must not kill running sandboxes. When the Auto Scaling
group decides to remove a client instance, that instance should stop accepting
new sandboxes, keep serving the ones it has until they end on their own, and only
then be terminated.

Non-goals:

- **Scale-out.** No scaling policy is proposed here; the pool still changes size
  only by hand or by an instance refresh. Scale-in correctness has to exist
  before automatic scale-out is safe to add, not the other way round.
- **Pausing sandboxes to drain faster.** Sandboxes are allowed to finish
  naturally. The tier-level cap makes that bounded — see Constraints.
- **The build and api pools.** `template-manager` sets `FORCE_STOP = "true"`
  deliberately (`nomad/origin/template-manager.hcl`), and the api pool holds no
  sandbox state.
- **Making `nomad job stop` / `nomad node drain` graceful.** That is a deploy
  concern with its own trade-offs; see "Deliberately not done".

## Current state

Verified on the live `e2b-dev` deployment (re-verified 2026-09-02).

### The ASG will terminate instances with no warning

```
client ASG:  min 0, desired 1, max 5
scaling policies:  none
lifecycle hooks:   none
termination policy: Default
scale-in protection: off
health check: EC2, grace 300s
```

No policy means no automatic scale-in today. Termination still happens through
three paths: a manual desired-capacity change, an instance refresh, and EC2
health-check replacement. With `max = 5`, adding any scale-out policy later
immediately creates scale-in events that nothing is prepared for.

Instance refresh is no longer an operator-only path. Since `f9164b836` the client
ASG carries an `instance_refresh` block, so **every launch-template change made by
`terraform apply` replaces the running node**. Its preferences are
`min_healthy_percentage = 0`, chosen so a refresh can start on a one-node pool:
that is terminate-before-launch. Today that costs the time a new node takes to
boot. Once the lifecycle hook below exists, the terminated node first drains for
up to 65 minutes — and with terminate-first the replacement does not launch until
it is gone, so a routine apply would leave the pool with no capacity for the
whole drain. See "Instance refresh preferences" under Design.

### The orchestrator already implements drain, and the API can trigger it

`packages/orchestrator/info.proto` defines the semantics:

> `Draining` means the node is bound to be shut down. It will not accept new
> sandboxes and will stop once all existing sandboxes are done.

Two paths set that status:

1. **On shutdown** (`packages/orchestrator/pkg/factories/run.go:1061-1094`, unless
   `FORCE_STOP` is set — which `orchestrator.hcl` does not set): set `Draining`,
   sleep 15s, `DrainSandboxes()` polls the live count to zero
   (`pkg/server/main.go:341`), then close services. This path is not used by this
   design; it only runs when Nomad stops the task.
2. **On request.** `POST /nodes/{nodeID}` (`AdminApiKeyAuth`) calls
   `node.SendStatusChange`, which is a gRPC `ServiceStatusOverride` to the
   orchestrator itself (`api/internal/orchestrator/nodemanager/status.go:137-154`,
   `orchestrator/pkg/service/info.go:59-77`). **The status lives in the
   orchestrator process, not in the api replica that took the request.** Every
   api replica re-reads it from `ServiceInfo` every `cacheSyncTime = 20s`
   (`api/internal/orchestrator/cache.go:23`) and `Node.CanAcceptNewRequests()`
   then gates placement (`placement/placement_best_of_K.go`). This is what makes
   the design correct with two api replicas behind one ALB: whichever replica the
   ALB picks, the other one sees the same status within 20s.

`OverrideStatus` only refuses `Draining -> Standby`; nothing at runtime resets the
status, but the initial status of a fresh process is `Healthy`
(`info.go:94`). See failure mode "orchestrator restarts mid-drain".

### What the API can and cannot see about a node

This shapes the drain-complete check, so it is spelled out:

- `GET /nodes/{nodeID}` returns `NodeDetail`, whose `sandboxCount` is the
  orchestrator's own live count (`MetricSandboxesRunning` ← `sandboxes.Count()`,
  `orchestrator/pkg/service/service_info.go:90`). It is the same number from
  either api replica.
- `NodeDetail` has **no** `sandboxStartingCount`. That field exists only on the
  `GET /nodes` list entries, and there it is `PlacementMetrics.InProgressCount()`
  of the replica that answered — a replica-local number, useless as a cluster-wide
  barrier.
- The orchestrator's count only includes **live** sandboxes (`sandbox/map.go:93`).
  A sandbox is promoted to live by `MarkRunning` at the **end** of `Create`
  (`pkg/server/sandboxes.go:1555`), after template fetch and VM boot. During that
  window it is invisible to the API. The orchestrator has a `startingSandboxes`
  semaphore internally but does not report it.
- `Create` does not check `Draining`. There is no admission fence on the
  orchestrator side; the only gate is the api's placement check.
- On the api side, `sandboxStore.Reserve` runs before placement and is a per-team
  quota, not a per-node record; `sandboxStore.Add` runs after `Create` returns.
  Redis therefore also cannot tell which node a sandbox is *being* created on.

The one bound that does exist: `Create` runs under a hard
`requestTimeout = 60s` (`sandboxes.go:49`). An in-flight create either becomes
live or fails within 60s of starting.

### Gaps, all in the deployment layer

| # | Gap | Consequence |
|---|---|---|
| 1 | No ASG lifecycle hook | EC2 terminates the instance immediately; nothing waits for anything. |
| 2 | `admin_token` is regenerated by `infra-iac/terraform/start.sh:191` on every terraform run, and `nomad/origin/api.hcl:169-170` feeds the **same value** to both `ADMIN_TOKEN` and `SANDBOX_ACCESS_TOKEN_HASH_SEED` | Any automation authenticating with it breaks after the next apply — already broken today: the running api holds one value, `/opt/config.properties` another, and `GET /nodes` returns 401. Worse, every apply also rotates the seed that validates sandbox traffic access tokens (`handlers/store.go:303`), and handing the admin credential to a Lambda would hand over that seed too. |
| 3 | `orchestrator.hcl:74` sets `NODE_ID = "${node.unique.id}"` (the Nomad UUID). Upstream's job (`iac/modules/job-orchestrator/jobs/orchestrator.hcl`) uses `${node.unique.name}`, which in our `run-nomad.sh` is the EC2 instance id | ASG lifecycle events carry only the instance id, so with the UUID something has to bridge the two — an extra Nomad lookup, a Nomad ACL token in the Lambda, server discovery, and a 4646 security-group rule, all to recover a mapping upstream never needed. |

## Constraints

- **Sandbox lifetime is capped at 1 hour.** Tier `base_v1` has
  `max_length_hours = 1` (migration `20240219190940`); the API's default
  `timeout` is 15s (`sandboxtypes/states.go:102`); the cap is enforced as total
  lifetime from `StartTime`, so timeout extensions cannot escape it
  (`api/internal/orchestrator/keep_alive.go:28-32`). A node's drain therefore
  lasts at most as long as the newest sandbox on it, with a one-hour ceiling. If
  a customer is later given a wider tier, the ceiling moves with it — the drain
  budget below has to be reviewed when that happens.
- **Nothing outside the orchestrator can see a sandbox that is being created.**
  The last placement onto a node can happen up to 20s after its status flips
  (the slowest api replica's next sync), and that create is visible or failed
  60s later. So a zero read is only trustworthy once the node has been draining
  for **at least 80s**; the design uses **120s** for margin. This is the quiet
  period.
- **Lifecycle action events are best-effort.** AWS: *"Amazon EC2 Auto Scaling
  sends events to EventBridge when an instance transitions into a wait state.
  Events are produced on a best-effort basis."* An event-driven design alone can
  therefore lose a termination and let the hook's `default_result` release the
  instance with sandboxes on it. The design needs a second way to notice an
  instance waiting in `Terminating:Wait`.
- **The lifecycle hook is the backstop against stalls, not against lost
  sandboxes.** With `default_result = CONTINUE`, a wedged automation ends with the
  instance released when the heartbeat times out. That protects the ASG; it does
  not protect the sandboxes. (`ABANDON` would also terminate the instance — for a
  terminating hook the two differ only in whether later hooks still run.)
- **Lambda runs for at most 15 minutes**, so a single invocation cannot hold a
  drain that may last an hour. The wait has to live outside the function.
- **The ASG's global timeout for a hook is `min(48h, 100 × heartbeat_timeout)`**
  — 8h20m at 300s. Heartbeats cannot extend past it. Fine for 65 min; re-check if
  the budget ever grows.

## Design

Two entry points start the same Standard state machine, one execution per
terminating instance, named after the instance id so a second start is rejected:

- **Fast path:** an EventBridge rule on the ASG's terminate lifecycle action,
  targeting a small **starter** Lambda.
- **Reconciler:** the same starter Lambda on a `rate(2 minutes)` schedule. It
  lists the client ASG's instances in `LifecycleState = Terminating:Wait` and
  starts an execution for each; `ExecutionAlreadyExists` means the fast path got
  there first and is ignored. Two minutes is chosen so that a missed event still
  leaves most of the 300s heartbeat window: worst case is miss + 120s + a cold
  start, comfortably under 300s.

The state machine heartbeats first and every loop, so no retry or wait can starve
the hook. One Lambda (`drain-step`) does all API work and is idempotent; the
machine only decides.

```
EventBridge rule (aws.autoscaling / "EC2 Instance-terminate Lifecycle Action" /
detail.AutoScalingGroupName = <prefix>-client-asg)  ──┐
                                                       ├──▶ starter Lambda ──▶ StartExecution(name = instance id)
EventBridge schedule rate(2 minutes) ─────────────────┘        (ExecutionAlreadyExists → ignore)

┌─────────────────────────────────────────────────────────────────────────┐
│ Standard state machine: drain-client-node                               │
│                                                                         │
│  Heartbeat            SDK: autoscaling:recordLifecycleActionHeartbeat    │
│    by InstanceId + hook name + ASG name (no token needed, so the         │
│    reconciler path works too). Catch "no active lifecycle action" → Done │
│         │                                                               │
│         ▼                                                               │
│  DrainStep            Lambda                                            │
│    GET  /nodes/{instance-id}                                            │
│    if status != draining: POST /nodes/{instance-id} {"status":"draining"}│
│         and record drainingSince = now  (also resets the quiet period    │
│         after an orchestrator restart)                                  │
│    returns {marked, sandboxCount, quietSeconds, notFound}               │
│         │                                                               │
│         ▼                                                               │
│  Choice  (JSONata; elapsed from $states.context.Execution.StartTime)    │
│    notFound for 3 consecutive loops        → Complete  (node is gone)    │
│    !marked and elapsed < 10 min            → Wait 30s → Heartbeat        │
│    !marked and elapsed ≥ 10 min            → Complete  (give up, alarm)  │
│    quietSeconds ≥ 120 and sandboxCount == 0                             │
│         and previous sandboxCount == 0     → Complete                    │
│    elapsed > 65 min                        → Complete  (give up, alarm)  │
│    otherwise                               → Wait 60s → Heartbeat        │
│         │                                                               │
│         ▼                                                               │
│  Complete             SDK: autoscaling:completeLifecycleAction CONTINUE  │
│    Catch "no active lifecycle action" → Done (hook already expired)      │
└─────────────────────────────────────────────────────────────────────────┘
```

`drain-step` is called with the instance id from the execution input; under the
node-identity change below that id **is** the API's `nodeID`, so there is no
lookup step at all.

### Why Step Functions, and why the reconciler came back

The first draft had a scheduled Lambda reconciling `Terminating:Wait` every
minute, and was replaced by the pure event-driven design on the argument that
`default_result = CONTINUE` already bounds every failure, so a poller was "a
second copy of insurance the ASG provides for free". That argument was wrong in
one place: `CONTINUE` insures against a *stuck ASG*, not against *lost
sandboxes*. Since lifecycle events are documented best-effort, dropping the
poller turned "the event was missed" from a recoverable delay into the exact
outcome the design exists to prevent. The reconciler is back, at a cadence chosen
against the heartbeat window rather than every minute.

Step Functions still carries the wait. `Wait` is a native state, both autoscaling
calls are AWS SDK integrations, and each execution's history shows one node's
drain loop by loop — a scheduled poller has to reconstruct that from logs.

| | This design | Pure event-driven (first draft) | Poller only |
|---|---|---|---|
| Missed event | picked up ≤ 2 min later, drain proceeds | instance released at 300s, sandboxes lost | picked up next tick |
| Idle cost | ~21.6k starter invocations/month, no executions | zero | ~43k invocations/month |
| Per scale-in | ~4 state transitions per loop, ~260 over 65 min, ≈ $0.0065 | same | — |
| Visibility | one execution per node | same | logs only |

### Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `heartbeat_timeout` | **300s** | Heartbeats are sent every loop, so the timeout only has to cover one loop plus a cold start. A wedged execution releases the instance in five minutes instead of an hour. |
| Loop interval | 60s (30s while the node is not yet marked) | One heartbeat per loop; short loops while marking so a transient API failure is retried quickly without starving the hook. |
| Quiet period | **120s** after `drainingSince` | 20s api sync + 60s `Create` timeout + margin; see Constraints. Reset whenever `drain-step` has to re-mark the node. |
| Confirmation | two consecutive zero reads | Belt and braces on top of the quiet period; also covers `waitSandboxLifecycles` cleanup after the last sandbox ends. |
| Max drain | **65 min** | Tier `max_length_hours = 1` bounds sandbox life at an hour; five minutes of margin, then give up, complete, and alarm. Revisit if any tier is widened. |
| Give-up while unmarked | 10 min | If the API cannot be reached to mark the node for ten minutes, the cluster is already unusable; holding one termination open does not help. Alarm. |
| `default_result` | `CONTINUE` | Failure releases the instance rather than stalling the ASG. |
| Reconciler rate | 2 min | Bounded by the 300s heartbeat window; see above. |
| EventBridge target `MaximumEventAgeInSeconds` | 240 | A delivery retried past the hook's lifetime would only operate on an expired action. Undeliverable events go to a DLQ. |

### Instance refresh preferences

The hook changes what a refresh costs, so the refresh has to change with it:
`min_healthy_percentage = 100`, `max_healthy_percentage = 200`
(launch-before-terminate). The replacement is launched and healthy first; only
then does the old node enter `Terminating:Wait` and drain. A one-node pool keeps
one serving node throughout, and a refresh takes boot time plus drain time
instead of leaving a gap for both. The AWS constraint is
`max − min ≤ 100`, which `100 / 200` satisfies; the provider in use (aws 5.100)
supports `max_healthy_percentage`. The cost is one extra bare-metal node for the
duration of the drain — the same cost the first rehearsal needed anyway.

This is a hard prerequisite of step 1, not a tuning: adding the hook with the
current `0 / 100` preferences turns every `terraform apply` that touches the
launch template into a drain-length outage.

### Node identity: adopt upstream's `NODE_ID`

`orchestrator.hcl` changes `NODE_ID` from `${node.unique.id}` to
`${node.unique.name}`, matching upstream. In our `run-nomad.sh` the node name is
the EC2 instance id (`name = "$instance_name"`, from instance metadata), so the
value in the lifecycle event, the Nomad node name and the API's `nodeID` become
the same string. The Lambda talks to exactly one system: the E2B API.

What the UUID design would have needed and this removes: Nomad ACL token in the
Lambda, `ec2:DescribeInstances` to find Nomad servers, a 4646 rule on the server
security group, VPC placement of the Lambda, and a `Status == ready` filter to
avoid picking up the stale UUID a re-registered client leaves behind.

**Migration is the cost, and it is not free.** `NODE_ID` is persisted in sandbox
state (`sandbox.NodeID`, `sandboxtypes/sandbox.go:113`), so while UUID-identified
and instance-id-identified nodes coexist, a controller that speaks only instance
ids cannot drain the old ones — and the rotation that would retire them is the
very thing that needs the controller. Changing the env var is also a destructive
system-job update, and the *old* allocation stops under today's 5s kill budget.
The clean path is: scale the client pool to 0, switch the job spec, scale back
up. On `e2b-dev` that is one command each way and acceptable. Anywhere it is not,
the Lambda must accept both identities for the transition.

### Network and credentials

| Concern | Decision |
|---|---|
| Lambda placement | **Not in the VPC** for `PublicAccess = Public`: the only dependency is `https://api.<domain>` on the internet-facing ALB, plus Secrets Manager and Auto Scaling APIs. No ENI, no NAT hairpin, no security group. For `Private`, the ALB is internal, so both Lambdas go into the private subnets (each must have a `0.0.0.0/0 → NAT` route, or Secrets Manager needs a VPC endpoint). |
| Reaching the E2B API | `https://api.<domain>` through the ALB, like every other client. Not the api nodes' private `:50001`: that would mean a second discovery path for no gain. |
| Credentials | `admin_token`, read from Secrets Manager at invocation. It becomes a stable secret first (prerequisite 1); until then the running api and the config file disagree. |
| starter Lambda IAM | `states:StartExecution` on the state machine, `autoscaling:DescribeAutoScalingGroups` |
| drain-step Lambda IAM | `secretsmanager:GetSecretValue` on the admin-token secret |
| State machine IAM | `lambda:InvokeFunction` on `drain-step`, `autoscaling:RecordLifecycleActionHeartbeat`, `autoscaling:CompleteLifecycleAction` |
| EventBridge IAM | the rule's target role needs `lambda:InvokeFunction` on the starter (the first draft's IAM table omitted the EventBridge side entirely) |
| Alarms | `ExecutionsFailed`, `ExecutionsTimedOut`, DLQ depth > 0, and a custom metric for every "give up" completion. Without these the give-up paths are silent. |

### Idempotency

- Executions are named by instance id. Standard workflows reject a duplicate name,
  which is what lets the fast path and the reconciler race safely. EventBridge
  cannot name an execution when it targets Step Functions directly — `PutTargets`
  has no field for it — which is the reason for the starter Lambda.
- Heartbeat and Complete identify the action by instance id + hook name + ASG
  name, not by `LifecycleActionToken`, so an execution started by the reconciler
  (which has no token) behaves identically.
- Both SDK calls catch the "no active lifecycle action" error and end the
  execution successfully: the hook may already have expired while the loop was
  still running. The exact error name follows Step Functions' `ServiceName.ErrorName`
  convention and is confirmed in the rehearsal before the `Catch` is narrowed from
  `States.TaskFailed`.
- `drain-step` is safe to repeat: it only POSTs when the status is not already
  `draining`.

## Failure modes

| Failure | Behaviour |
|---|---|
| EventBridge does not deliver the event | The reconciler starts the execution within 2 min; roughly half the 300s window is still left; the drain proceeds normally. |
| Both entry points fail (Lambda service issue, bad IAM) | No heartbeat is ever sent; `CONTINUE` releases the instance at 300s. Sandboxes on it are lost. Bounded, and visible: the alarm on failed executions / an instance that passed through `Terminating:Wait` with no execution fires. |
| `drain-step` cannot reach the E2B API | The loop keeps heartbeating every 30s so the hook stays alive while the API is retried. After 10 min unmarked it gives up, completes, and alarms. The node stayed `Ready` throughout, so the API kept placing on it — the worst case, and why marking is retried first and often. |
| Orchestrator restarts mid-drain | `restart { attempts = 0 }` stops in-place restarts, but the system scheduler re-places the allocation on the same node; the new process starts `Healthy`. The next `drain-step` sees `status != draining`, re-marks, and resets the quiet period. Exposure is one loop plus one api sync, ≤ 80s, and any sandbox placed in that window is simply waited for. (A crash also kills that node's sandboxes, so the drain goal is already lost for them.) |
| `GET /nodes/{id}` returns 404 | Could be the node genuinely gone (allocation lost, api discovery dropped it) or a replica that just restarted and has not synced. Three consecutive 404s across ≥ 2 min are treated as "gone" and the action is completed; fewer are retried. |
| Sandboxes outlive the 65-minute budget | Give up, complete, alarm; the instance terminates with sandboxes on it. Only reachable if a tier allows sessions longer than an hour. |
| Hook expires while the execution is still looping | Heartbeat/Complete fail with "no active lifecycle action"; caught, execution ends. |
| Duplicate event delivery | Starter's `StartExecution` fails with `ExecutionAlreadyExists`; ignored. |
| Two instances terminate at once | Two independent executions. Nothing shared. |
| Node has zero sandboxes at termination | Marked, quiet period 120s, one confirming read: the instance terminates about three minutes after the action began. |

## Prerequisites

Both are fixes worth making regardless of this design.

1. **Split `admin_token` from the sandbox token seed, and make both stable.**
   Terraform generates two secrets with `random_password`, `${prefix}-admin-token`
   and `${prefix}-sandbox-access-token-hash-seed`, the way the other six secrets
   already work; `start.sh` reads them instead of calling `openssl`; `api.hcl`
   reads `SANDBOX_ACCESS_TOKEN_HASH_SEED` from the new key. On a stack with live
   sandboxes the seed must be **initialised to the value the running api currently
   holds**, or every existing sandbox access token is invalidated at the switch.
   On `e2b-dev` a one-time invalidation is acceptable; on anything else, import
   the running value.
2. **`NODE_ID` → `${node.unique.name}`**, with the client pool scaled to 0 for
   the switch. See "Node identity".

## Deliberately not done

**No `kill_timeout` on the orchestrator job.** The first draft listed it as a
prerequisite. It is not needed by this design — by the time the hook completes
the node is empty and the orchestrator exits at once — and adding it changes
deploy semantics in a way that needs its own decision:

- `orchestrator.hcl` is a `system` job with no `update` block. Nomad injects a
  default update strategy **only for service jobs** (`api/jobs.go`
  `Canonicalize`: `else if *j.Type == JobTypeService`); the server side injects
  none; and the system scheduler only limits parallelism when
  `job.Update.Rolling()` is true, which needs `MaxParallel > 0`
  (`scheduler/scheduler_system.go`, Nomad v1.8.4). So a spec change replaces the
  allocation on **every** client node in one evaluation.
- With a long `kill_timeout`, each of those old allocations enters `Draining`
  and holds for up to the timeout. Every deploy becomes a cluster-wide window in
  which no sandbox can be placed — up to 15 minutes at the value first proposed,
  and 15 minutes still SIGKILLs any sandbox with more than 15 minutes left, so it
  would not have been graceful either.
- Upstream sets no `kill_timeout` on its orchestrator job. It versions the job
  name (`orchestrator-${latest_orchestrator_job_id}`) and constrains it to nodes
  carrying a matching `meta.orchestrator_job_version`, so upgrades arrive by
  replacing nodes — which is exactly the path this design makes safe.

If graceful `nomad job stop` is wanted later, it needs `kill_timeout` **and** an
explicit `update { max_parallel = 1 }` (system jobs get none by default), and
`deploy-all.sh` / HANDOFF must state that a deploy then takes up to the timeout
per node.

## Implementation plan

| Step | Files | Verification |
|---|---|---|
| 0a | `infra-iac/terraform/main.tf`, `infra-iac/terraform/start.sh`, `nomad/origin/api.hcl` | two secrets exist; values stable across two consecutive applies; `GET /nodes` returns 200 with the secret's value; an existing sandbox's traffic token still works after the api redeploy (or the invalidation was accepted) |
| 0b | `nomad/origin/orchestrator.hcl` | client pool at desired 0 → spec change → desired 1; `GET /nodes` lists the instance id as `id`; a sandbox can be created |
| 1 | `infra-iac/terraform/main.tf` | lifecycle hook on the client ASG (`heartbeat_timeout = 300`, `default_result = CONTINUE`) **and** `instance_refresh` preferences moved to `min_healthy_percentage = 100`, `max_healthy_percentage = 200` in the same apply; a termination visibly pauses in `Terminating:Wait`; a launch-template change launches the replacement before the old node is terminated |
| 2 | `infra-iac/lambda/drain-warden/` (`starter`, `drain-step`) plus terraform | invoke `drain-step` directly with the live instance id: returns `status`, `sandboxCount`; a second call is a no-op |
| 3 | terraform: state machine, EventBridge rule + target role + `MaximumEventAgeInSeconds` + DLQ, scheduled rule, alarms | **rehearsal A:** start a sandbox with a long timeout, trigger a refresh (`start-instance-refresh`, or any launch-template change), confirm the replacement is `InService` before the old node enters `Terminating:Wait`, and watch the execution hold that node until the sandbox ends while new sandboxes land on the replacement |
| 3b | — | **rehearsal B:** disable the EventBridge rule, lower desired capacity by one, confirm the reconciler starts the execution within 2 min and the drain completes |
| 3c | — | **rehearsal C:** while an execution is looping, `nomad alloc stop` the orchestrator on that node; confirm the next `drain-step` re-marks and the quiet period restarts |

The rehearsals need `aws autoscaling start-instance-refresh` and a
desired-capacity change, which the operator runs.

## Open items

- The SDK integrations
  `arn:aws:states:::aws-sdk:autoscaling:recordLifecycleActionHeartbeat` and
  `:completeLifecycleAction` are assumed to exist and their error names assumed
  to follow `AutoScaling.<ErrorName>`. Confirmed in rehearsal A. Fallback: move
  both calls into `drain-step`; nothing else changes.
- Whether to also protect a busy node from being *chosen* for scale-in
  (`NewInstancesProtectedFromScaleIn` plus a controller that clears protection
  when a node is empty). Not needed for correctness, since draining is graceful
  whichever node is picked, and it adds a second control loop. Deferred.
- The 65-minute budget is derived from a tier value in the database. Nothing
  currently notices if that value changes. A cheap guard would be for
  `drain-step` to read the tier cap and fail loudly if it exceeds the budget.
- The quiet period exists only because the orchestrator has no admission fence:
  `Create` does not refuse when the node is `Draining`, and starting sandboxes
  are not reported. An upstream change to either would let the check become
  exact. Worth proposing upstream; not something this repository patches, since
  `packages/` is replaced wholesale on every sync.
- Upstream's shutdown drain sleeps 15s "so the new status reaches every API
  replica", but the api sync period is 20s. Irrelevant here (the quiet period is
  120s) and only affects the `nomad job stop` path this design does not use.

## Revision notes (2026-09-02)

Changes from the first draft, each traced to a finding of the cross-review:

- **Reconciler restored.** The first draft argued it was redundant with
  `default_result = CONTINUE`; that conflated "the ASG never stalls" with
  "sandboxes are never lost". Lifecycle events are documented best-effort.
- **Drain-complete check rewritten.** `sandboxStartingCount` is not on
  `NodeDetail`, and where it exists it is replica-local. The check now uses the
  orchestrator's live count with a 120s quiet period derived from `cacheSyncTime`
  and `Create`'s `requestTimeout`, plus two confirming reads.
- **Node identity switched to upstream's `${node.unique.name}`.** Removes Nomad,
  server discovery, the ACL token and the VPC from the Lambda. Migration cost
  written down.
- **`kill_timeout` prerequisite dropped**, with the Nomad system-job update
  semantics that make it a deploy-time outage risk.
- **`admin_token` prerequisite widened**: it is also the sandbox token hash seed;
  two secrets, seed preserved on migration.
- **Heartbeat moved to the front of every loop**; marking retried under
  heartbeat; re-mark after orchestrator restart; 404 requires confirmation;
  "no active lifecycle action" handled; idempotency via a starter Lambda because
  EventBridge cannot name executions.
- **Instance refresh preferences made part of step 1.** `f9164b836` added a
  terraform-driven `instance_refresh` with `min_healthy_percentage = 0`; combined
  with the hook that would turn every launch-template change into a drain-length
  capacity gap on a one-node pool. Launch-before-terminate (`100 / 200`) fixes it.
- **Document fixes**: EventBridge IAM role, ~260 transitions not ~180, `ABANDON`
  also terminates, the 8h20m global timeout, alarms on the give-up paths.
