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
    assert_contains(hugepages_job, "job_name: e2b-orphan-fc", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "node_pool: default", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_hugepages_free", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_firecracker_orphan_processes", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_firecracker_ppid_1_processes", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_nbd_no_pid_nonzero_size_devices", "nomad/origin/otel-hugepages-collector.hcl")
    assert_contains(hugepages_job, "e2b_host_orphan_audit_success", "nomad/origin/otel-hugepages-collector.hcl")

    service_limits = [
        "StartLimitIntervalSec=300",
        "StartLimitBurst=3",
        "RestartSec=30",
        "CPUAccounting=true",
        "MemoryAccounting=true",
        "IOAccounting=true",
        "CPUQuota=20%",
        "MemoryMax=128M",
        "TasksMax=32",
        "Nice=10",
        "IOSchedulingClass=idle",
        "NoNewPrivileges=true",
        "ProtectHome=true",
    ]

    start_client = read("infra-iac/terraform/scripts/start-client.sh")
    assert_contains(start_client, "e2b-hugepages-metrics.service", "infra-iac/terraform/scripts/start-client.sh")
    for directive in service_limits:
        assert_contains(start_client, directive, "infra-iac/terraform/scripts/start-client.sh")

    orphan_installer = read("infra-iac/terraform/scripts/install-orphan-fc-exporter.sh")
    assert_contains(orphan_installer, "e2b-orphan-fc-exporter.service", "infra-iac/terraform/scripts/install-orphan-fc-exporter.sh")
    for directive in service_limits:
        assert_contains(orphan_installer, directive, "infra-iac/terraform/scripts/install-orphan-fc-exporter.sh")

    op_script = read("artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, 'DEPLOY_BRANCH="0303"', "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, "git fetch origin", "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, "git pull --ff-only origin", "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, "ORPHAN_FC_EXPORTER_SCRIPT_SYNCED", "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, 'exec "$script_path" "$@"', "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    assert_contains(op_script, "e2b-hugepages-metrics.service.d/resource-limits.conf", "artifacts/deploy_orphan_fc_exporter_to_clients.sh")
    for directive in service_limits:
        assert_contains(op_script, directive, "artifacts/deploy_orphan_fc_exporter_to_clients.sh")

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
