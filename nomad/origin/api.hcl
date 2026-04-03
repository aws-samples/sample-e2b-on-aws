job "api" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool = "api"
  priority = 90

  group "api-service" {
    network {
      port "api" {
        static = "50001"
      }
    }

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    service {
      name = "api"
      port = "50001"
      task = "start"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "50001"
      }
    }



    task "start" {
      driver       = "docker"
      # If we need more than 30s we will need to update the max_kill_timeout in nomad
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
      kill_timeout = "30s"
      kill_signal  = "SIGTERM"

      resources {
        memory_max = 8192
        memory     = 8192
        cpu        = 4000
      }

      env {
        NODE_ID                        = "$${node.unique.id}"
        POSTGRES_CONNECTION_STRING     = "${CFNDBURL}"
        AUTH_DB_CONNECTION_STRING      = "${CFNDBURL}"
        ENVIRONMENT                    = "${environment}"
        ADMIN_TOKEN                    = "${admin_token}"
        NOMAD_TOKEN                    = "${nomad_acl_token}"
        CONSUL_HTTP_TOKEN              = "${consul_http_token}"
        REDIS_CLUSTER_URL                      = "${REDIS_ENDPOINT}:6379"
        REDIS_TLS_ENABLED                = "true"
        REDIS_TLS_CA_BASE64          = ""
        LOKI_URL                       = "http://loki.service.consul:3100"
        DOMAIN_NAME                    = "${CFNDOMAIN}"
        DNS_PORT                       = 5353
        SANDBOX_ACCESS_TOKEN_HASH_SEED = "${admin_token}"
        OTEL_TRACING_PRINT             = "false"
        OTEL_COLLECTOR_GRPC_ENDPOINT   = "localhost:4317"
        LOGS_COLLECTOR_ADDRESS         = "http://localhost:30006"
        # Volume token config - dummy values since volumes are not yet used
        VOLUME_TOKEN_ISSUER            = "e2b"
        VOLUME_TOKEN_SIGNING_METHOD    = "HS256"
        VOLUME_TOKEN_SIGNING_KEY       = "HMAC:c2tpcA=="
        VOLUME_TOKEN_SIGNING_KEY_NAME  = "default"
        # These are here because they are transitively required
        TEMPLATE_BUCKET_NAME           = "${BUCKET_E2B}"
        STORAGE_PROVIDER               = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER    = "AWS_ECR"
        AWS_REGION                     = "${AWSREGION}"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/api:latest"
        ports        = ["api"]
        args         = [
          "--port", "50001",
        ]
        volumes = [
          "/var/run/docker.sock:/var/run/docker.sock",
        ]
      }
    }
  }
}
