#!/usr/bin/env python3
"""Checks for Nomad observability deployment configuration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def assert_contains(text: str, needle: str, source: str) -> None:
    if needle not in text:
        raise AssertionError(f"{source} is missing {needle!r}")


def assert_not_contains(text: str, needle: str, source: str) -> None:
    if needle in text:
        raise AssertionError(f"{source} should not contain {needle!r}")


def main() -> None:
    otel = read("nomad/origin/otel-collector.hcl")

    expected_nomad_metrics = [
        "nomad_nomad_job_status_running",
        "nomad_nomad_job_status_pending",
        "nomad_nomad_job_summary_failed",
        "nomad_nomad_job_summary_lost",
        "nomad_nomad_job_summary_queued",
        "nomad_nomad_plan_queue_depth",
        "nomad_nomad_blocked_evals_total_blocked",
        "nomad_nomad_blocked_evals_total_escaped",
        "nomad_nomad_broker_total_pending",
        "nomad_nomad_broker_total_unacked",
        "nomad_nomad_autopilot_healthy",
        "nomad_nomad_autopilot_failure_tolerance",
        "nomad_raft_leader_lastContact",
        "nomad_raft_leader_oldestLogAge",
        "nomad_raft_thread_fsm_saturation",
        "nomad_raft_thread_main_saturation",
        "nomad_nomad_rpc_request",
        "nomad_nomad_rpc_query",
        "nomad_nomad_rpc_eval_write",
        "nomad_nomad_client_update_status",
        "nomad_memberlist_size_local",
        "nomad_memberlist_gossip",
        "nomad_nomad_heartbeat_active",
    ]
    for metric in expected_nomad_metrics:
        assert_contains(otel, f'"{metric}"', "nomad/origin/otel-collector.hcl")

    expected_otlp_metric_patterns = [
        "orchestration-api\\\\.http\\\\..*",
        "rpc\\\\.client\\\\.duration.*",
        "rpc\\\\.client\\\\.request\\\\.size.*",
        "rpc\\\\.client\\\\.response\\\\.size.*",
        "rpc\\\\.client\\\\.requests_per_rpc.*",
        "rpc\\\\.client\\\\.responses_per_rpc.*",
    ]
    for pattern in expected_otlp_metric_patterns:
        assert_contains(otel, f'"{pattern}"', "nomad/origin/otel-collector.hcl")

    assert_not_contains(otel, "job_name: e2b-hugepages", "nomad/origin/otel-collector.hcl")

    hugepages_job_path = ROOT / "nomad/origin/otel-hugepages-collector.hcl"
    if not hugepages_job_path.exists():
        raise AssertionError("nomad/origin/otel-hugepages-collector.hcl is missing")
    hugepages_job = hugepages_job_path.read_text()
    assert_contains(hugepages_job, 'node_pool   = "default"', "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "job_name: e2b-hugepages", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "node_pool: default", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_hugepages_free", "nomad/origin/otel-hugepages-collector.hcl")

    event_job_path = ROOT / "nomad/origin/nomad-event-collector.hcl"
    if not event_job_path.exists():
        raise AssertionError("nomad/origin/nomad-event-collector.hcl is missing")
    event_job = event_job_path.read_text()
    assert_contains(event_job, 'node_pool   = "default"', "nomad/origin/nomad-event-collector.hcl")
    for topic in ["Deployment", "Evaluation", "Allocation", "Node", "Job"]:
        assert_contains(event_job, topic, "nomad/origin/nomad-event-collector.hcl")
    assert_contains(event_job, "https://${attr.unique.network.ip-address}:4646", "nomad/origin/nomad-event-collector.hcl")
    assert_contains(event_job, "http://127.0.0.1:4318/v1/logs", "nomad/origin/nomad-event-collector.hcl")
    assert_contains(event_job, "raw_payload_enabled = false", "nomad/origin/nomad-event-collector.hcl")
    assert_contains(event_job, "data        = <<PY", "nomad/origin/nomad-event-collector.hcl")
    assert_contains(event_job, "def current_nomad_index():", "nomad/origin/nomad-event-collector.hcl")

    deploy = read("nomad/deploy.sh")
    assert_contains(deploy, '["otel-hugepages-collector"]', "nomad/deploy.sh")
    assert_contains(deploy, "deploy/otel-hugepages-collector-deploy.hcl", "nomad/deploy.sh")
    assert_contains(deploy, '["nomad-event-collector"]', "nomad/deploy.sh")
    assert_contains(deploy, "deploy/nomad-event-collector-deploy.hcl", "nomad/deploy.sh")


if __name__ == "__main__":
    main()
