job "otel-hugepages-collector" {
  datacenters = ["us-west-2a", "us-west-2b"]
  type        = "system"
  node_pool   = "default"

  priority = 95

  group "otel-hugepages-collector" {
    task "start-collector" {
      driver = "docker"

      config {
        network_mode   = "host"
        image          = "artifactory.aic.aws.zoomdev.us/zoom-docker-virtual/otel/opentelemetry-collector-contrib:0.130.0"
        auth_soft_fail = true
        args = [
          "--config=local/config/otel-hugepages-collector-config.yaml",
          "--feature-gates=pkg.translator.prometheus.NormalizeName",
        ]
      }

      resources {
        memory_max = 512
        memory     = 128
        cpu        = 100
      }

      template {
        data = <<EOF
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: e2b-hugepages
          scrape_interval: 15s
          scrape_timeout: 5s
          metrics_path: /metrics
          static_configs:
            - targets: ['127.0.0.1:9108']
              labels:
                node_pool: default
        - job_name: e2b-orphan-fc
          scrape_interval: 15s
          scrape_timeout: 5s
          metrics_path: /metrics
          static_configs:
            - targets: ['127.0.0.1:9109']
              labels:
                node_pool: default

processors:
  batch:
    timeout: 15s
    send_batch_size: 1500
    send_batch_max_size: 2000

  filter/hugepages:
    metrics:
      include:
        match_type: strict
        metric_names:
          - "up"
          - "e2b_host_hugepage_size_bytes"
          - "e2b_host_hugetlb_bytes"
          - "e2b_host_mem_available_bytes"
          - "e2b_host_hugepages_total"
          - "e2b_host_hugepages_free"
          - "e2b_host_hugepages_reserved"
          - "e2b_host_hugepages_surplus"
          - "e2b_host_hugepages_persistent_configured"
          - "e2b_host_hugepages_overcommit_configured"
          - "e2b_host_hugepages_total_bytes"
          - "e2b_host_hugepages_free_bytes"
          - "e2b_host_hugepages_reserved_bytes"
          - "e2b_host_hugepages_surplus_bytes"
          - "e2b_host_hugepages_free_ratio"
          - "e2b_host_hugepages_reserved_ratio"
          - "e2b_host_vmstat_pgfault_total"
          - "e2b_host_vmstat_pgfault"
          - "e2b_host_vmstat_pgmajfault_total"
          - "e2b_host_vmstat_pgmajfault"
          - "e2b_host_hugetlb_buddy_alloc_success_total"
          - "e2b_host_hugetlb_buddy_alloc_success"
          - "e2b_host_hugetlb_buddy_alloc_fail_total"
          - "e2b_host_hugetlb_buddy_alloc_fail"
          - "e2b_host_memory_pressure_some_avg10"
          - "e2b_host_memory_pressure_some_avg60"
          - "e2b_host_memory_pressure_some_avg300"
          - "e2b_host_memory_pressure_some_total"
          - "e2b_host_memory_pressure_some"
          - "e2b_host_memory_pressure_full_avg10"
          - "e2b_host_memory_pressure_full_avg60"
          - "e2b_host_memory_pressure_full_avg300"
          - "e2b_host_memory_pressure_full_total"
          - "e2b_host_memory_pressure_full"
          - "e2b_host_hugepages_free_sandbox_slots"
          - "e2b_host_hugepages_total_sandbox_slots"
          - "e2b_host_hugepages_reserved_sandbox_slots"
          - "e2b_host_numa_hugepages_total"
          - "e2b_host_numa_hugepages_free"
          - "e2b_host_numa_hugepages_surplus"
          - "e2b_host_firecracker_processes"
          - "e2b_host_firecracker_orchestrator_tracked_sandboxes"
          - "e2b_host_firecracker_orphan_processes"
          - "e2b_host_firecracker_orphan_oldest_age_seconds"
          - "e2b_host_firecracker_oldest_age_seconds"
          - "e2b_host_firecracker_ppid_1_processes"
          - "e2b_host_firecracker_without_unshare_wrapper"
          - "e2b_host_unshare_wrappers_total"
          - "e2b_host_firecracker_orphan_d_state_processes"
          - "e2b_host_firecracker_orphan_z_state_processes"
          - "e2b_host_nbd_active_devices"
          - "e2b_host_nbd_total_devices"
          - "e2b_host_nbd_pid_devices"
          - "e2b_host_nbd_nonzero_size_devices"
          - "e2b_host_nbd_no_pid_nonzero_size_devices"
          - "e2b_host_tmp_fc_sockets_total"
          - "e2b_host_tmp_fc_sockets_without_fc"
          - "e2b_host_netns_total"
          - "e2b_host_tap_devices_total"
          - "e2b_host_veth_devices_total"
          - "e2b_host_unshare_wrappers_without_fc"
          - "e2b_host_firecracker_d_state_processes"
          - "e2b_host_firecracker_z_state_processes"
          - "e2b_host_orphan_control_available"
          - "e2b_host_orphan_audit_success"
          - "e2b_host_orphan_audit_duration_seconds"

  resourcedetection:
    detectors: [ec2]
    override: true
    ec2:
      resource_attributes:
        cloud.provider:
          enabled: false
        cloud.platform:
          enabled: false
        cloud.account.id:
          enabled: false
        cloud.availability_zone:
          enabled: false
        cloud.region:
          enabled: false
        host.type:
          enabled: true
        host.id:
          enabled: true
        host.name:
          enabled: true

  transform/set-name:
    metric_statements:
      - delete_key(datapoint.attributes, "instance")
      - set(datapoint.attributes["service.instance.id"], resource.attributes["host.name"])

  resource/customer_enrich:
    attributes:
      - key: cluster
        value: ""
        action: upsert

exporters:
  otlphttp/customer:
    endpoint: ""

service:
  telemetry:
    logs:
      level: warn
  pipelines:
    metrics:
      receivers: [prometheus]
      processors: [filter/hugepages, resourcedetection, resource/customer_enrich, transform/set-name, batch]
      exporters: [otlphttp/customer]
EOF

        destination = "local/config/otel-hugepages-collector-config.yaml"
        change_mode = "restart"
      }
    }
  }
}
