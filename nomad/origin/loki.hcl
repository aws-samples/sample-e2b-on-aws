job "loki" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  type        = "service"
  node_pool = "api"

  priority = 75

  group "loki-service" {
    network {
      port "loki" {
        static = "3100"
      }
    }

    service {
      name = "loki"
      port = "loki"

      check {
        type     = "http"
        path     = "/ready"
        interval = "20s"
        timeout  = "2s"
        port     = "loki"
      }
    }

    task "loki" {
      driver = "docker"

      config {
        network_mode = "host"
        image = "grafana/loki:2.9.8"

        args = [
          "-config.file",
          "local/loki-config.yml",
        ]
      }

      resources {
        memory_max = 2048
        memory     = 1024
        cpu        = 500
      }

      template {
        data = <<EOF
auth_enabled: false

server:
  http_listen_port: 3100
  log_level: "warn"
  grpc_server_max_recv_msg_size: 104857600  # 100 Mb
  grpc_server_max_send_msg_size: 104857600  # 100 Mb

common:
  path_prefix: /loki
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

storage_config:
  aws:
    s3: "s3://${AWSREGION}/${BUCKET_LOKI_STORAGE}"
  tsdb_shipper:
    active_index_directory: /loki/tsdb-shipper-active
    cache_location: /loki/tsdb-shipper-cache
    cache_ttl: 24h
    shared_store: aws

chunk_store_config:
  chunk_cache_config:
    embedded_cache:
      enabled: true
      max_size_mb: 512
      ttl: 1h

query_range:
  align_queries_with_step: true
  cache_results: true
  max_retries: 5
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 256
        ttl: 1h

ingester_client:
  grpc_client_config:
    max_recv_msg_size: 104857600  # 100 Mb
    max_send_msg_size: 104857600  # 100 Mb

ingester:
  chunk_idle_period: 30m
  chunk_encoding: snappy
  chunk_target_size: 1048576  # 1MB
  wal:
    dir: /loki/wal
    flush_on_shutdown: true

schema_config:
 configs:
    - from: 2024-03-05
      store: tsdb
      object_store: aws
      schema: v12
      index:
        prefix: loki_index_
        period: 24h

compactor:
  working_directory: /loki/compactor
  compaction_interval: 10m
  retention_enabled: true
  retention_delete_delay: 2h
  retention_delete_worker_count: 150
  shared_store: aws

# The bucket lifecycle policy should be set to delete objects after MORE than the specified retention period
limits_config:
  retention_period: 168h
  ingestion_rate_mb: 100
  ingestion_burst_size_mb: 500
  per_stream_rate_limit: "80MB"
  per_stream_rate_limit_burst: "240MB"
  max_streams_per_user: 0
  max_global_streams_per_user: 10000
  unordered_writes: true
  reject_old_samples_max_age: 168h
EOF

        destination = "local/loki-config.yml"
      }
    }
  }
}
