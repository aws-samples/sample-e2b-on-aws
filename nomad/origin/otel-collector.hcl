job "otel-collector" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  type        = "system"
  node_pool   = "all"

  priority = 95

  group "otel-collector" {
    network {
      port "health" {
        to = 13133
      }

      port "metrics" {
        to = 8888
      }

      # Receivers
      port "grpc" {
        to = 4317
      }

      port "http" {
        to = 4318
      }

      port "sandbox_http" {
        to = 4319
      }
    }

    service {
      name = "otel-collector"
      port = "grpc"
      tags = ["grpc"]

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "20s"
        timeout  = "5s"
        port     = 13133
      }
    }

    task "start-collector" {
      driver = "docker"

      config {
        network_mode = "host"
        dns_servers  = ["127.0.0.53"]
        image        = "otel/opentelemetry-collector-contrib:0.130.0"
        auth_soft_fail = true
        volumes = [
          "local/config:/config",
        ]
        args = [
          "--config=local/config/otel-collector-config.yaml",
          "--feature-gates=pkg.translator.prometheus.NormalizeName",
        ]

        ports = [
          "metrics",
          "grpc",
          "health",
          "http",
          "sandbox_http",
        ]
      }

      resources {
        memory_max = 4096
        memory = 1024
        cpu    = 256
      }

      # Nomad agent (root) reads host-only files and renders them into the
      # task-local config dir. The collector container (non-root UID 10001)
      # reads from /config (= alloc/local/config), bypassing host permission
      # restrictions on /opt/nomad/tls/*.pem (0600 nomad:nomad) and
      # /opt/e2b/secrets/* (0600 root:root, dir 0700).
      template {
        destination = "local/config/nomad-ca.pem"
        data        = "{{ file \"/opt/nomad/tls/ca.pem\" }}"
        change_mode = "restart"
        perms       = "444"
      }

      template {
        destination = "local/config/nomad-cert.pem"
        data        = "{{ file \"/opt/nomad/tls/cert.pem\" }}"
        change_mode = "restart"
        perms       = "444"
      }

      template {
        destination = "local/config/nomad-key.pem"
        data        = "{{ file \"/opt/nomad/tls/key.pem\" }}"
        change_mode = "restart"
        perms       = "444"
      }

      template {
        data = <<EOF
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
        max_recv_msg_size_mib: 100
        read_buffer_size: 10943040
        max_concurrent_streams: 200
        write_buffer_size: 10943040
      http:
        endpoint: 0.0.0.0:4318
  otlp/sandbox:
    protocols:
      http:
        endpoint: 0.0.0.0:4319
  prometheus:
    config:
      scrape_configs:
        - job_name: nomad
          scrape_interval: 15s
          scrape_timeout: 5s
          metrics_path: '/v1/metrics'
          # Nomad 4646 HTTPS + mTLS (see run-nomad.sh: http=true, verify_https_client=true)
          # Certs/token are rendered by Nomad template into the task-local
          # config directory (`/config`, UID 10001 readable) — host paths are
          # root-owned 0600 and not accessible to the collector container.
          scheme: https
          tls_config:
            ca_file: /config/nomad-ca.pem
            cert_file: /config/nomad-cert.pem
            key_file: /config/nomad-key.pem
            insecure_skip_verify: true
          authorization:
            type: Bearer
            credentials: '{{ file "/opt/e2b/secrets/nomad_acl_token" }}'
          static_configs:
            - targets: ['localhost:4646']
          params:
            format: ['prometheus']

processors:
  batch:
    timeout: 15s
    send_batch_size: 1500
    send_batch_max_size: 2000


  # keep only metrics that are used
  filter/otlp:
    # https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/filterprocessor
    metrics:
      include:
        match_type: regexp
        metric_names:
          - "orchestrator.*"
          - "template.*"
          - "api.*"
          - "client_proxy.*"
          - "e2b\\.sandbox\\..*"      # per-sandbox cpu/ram gauges
          - "http\\..*"                  # api HTTP middleware histograms
          - "rpc\\..*"                   # otelgrpc client/server histograms
          - "otelcol_.*"                   # collector self-metrics


  filter/prometheus:
    metrics:
      include:
        match_type: strict
        metric_names:
          - "nomad_client_host_cpu_total_percent"
          - "nomad_client_host_cpu_idle"
          - "nomad_client_host_disk_available"
          - "nomad_client_host_disk_size"
          - "nomad_client_host_memory_available"
          - "nomad_client_host_memory_total"
          - "nomad_client_allocs_memory_usage"
          - "nomad_client_allocs_memory_allocated"
          - "nomad_client_allocs_cpu_total_percent"
          - "nomad_client_allocs_cpu_allocated"


  metricstransform:
    # https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/metricstransformprocessor
    transforms:
      - include: "nomad_client_host_cpu_idle"
        match_type: strict
        action: update
        operations:
          - action: aggregate_labels
            aggregation_type: sum
            label_set: [instance, node_id, node_status, node_pool]

  resourcedetection:
    # https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/resourcedetectionprocessor
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
      - delete_key(datapoint.attributes, "node_id")
      - delete_key(datapoint.attributes, "node_scheduling_eligibility")
      - delete_key(datapoint.attributes, "node_class")
      - delete_key(datapoint.attributes, "node_status")
      - delete_key(datapoint.attributes, "service_name")
      - set(datapoint.attributes["service.instance.id"], resource.attributes["host.name"])

  filter/rpc_duration_only:
    metrics:
      include:
        match_type: regexp
        # Include info about grpc server endpoint durations - used for monitoring request times
        metric_names:
          - "rpc.server.duration.*"
  resource/remove_instance:
    attributes:
      - action: delete
        key: service.instance.id
  resource/customer_enrich:
    attributes:
      - key: cluster
        value: "${otel_resource_cluster}"
        action: upsert
  filter/logs_severity:
    error_mode: ignore
    logs:
      log_record:
        - 'severity_number < SEVERITY_NUMBER_INFO'

extensions:
  health_check:
    endpoint: 0.0.0.0:13133

exporters:
  debug:
    verbosity: detailed
  # Customer OTel HTTP endpoint (no auth required)
  # Use http:// for insecure, https:// for TLS
  otlphttp/customer:
    endpoint: "${otel_customer_endpoint}"

service:
  telemetry:
    logs:
      level: warn
    metrics:
      readers:
        - periodic:
            exporter:
              otlp:
                protocol: grpc
                insecure: true
                endpoint: localhost:4317
  extensions:
    - health_check
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [filter/otlp, resourcedetection, resource/customer_enrich, transform/set-name, batch]
      exporters: [otlphttp/customer]
    metrics/prometheus:
      receivers: [prometheus]
      processors: [filter/prometheus, metricstransform, resourcedetection, resource/customer_enrich, transform/set-name, batch]
      exporters: [otlphttp/customer]
    metrics/rpc_only:
      receivers: [otlp]
      processors: [filter/rpc_duration_only, resource/remove_instance, resourcedetection, resource/customer_enrich, transform/set-name, batch]
      exporters: [otlphttp/customer]
    traces:
      receivers: [otlp]
      processors: [resource/customer_enrich, batch]
      exporters: [otlphttp/customer]
    logs:
      receivers: [otlp]
      processors: [filter/logs_severity, resource/customer_enrich, batch]
      exporters: [otlphttp/customer]
    logs/sandbox:
      receivers: [otlp/sandbox]
      processors: [resource/customer_enrich, batch]
      exporters: [otlphttp/customer]
EOF

        destination = "local/config/otel-collector-config.yaml"
      }
    }
  }
}
