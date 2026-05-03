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
        memory_max = 32768
        memory     = 32768
        cpu        = 8000
      }

      env {
        ORCHESTRATOR_PORT             = 5008
        TEMPLATE_MANAGER_HOST         = "template-manager.service.consul:5009"
        AWS_ENABLED                   = "true"
        AWS_DOCKER_REPOSITORY_NAME    = "e2bdev/base"
        AWS_REGION                   = "${AWSREGION}"
        CLICKHOUSE_CONNECTION_STRING   = ""
        CLICKHOUSE_USERNAME            = ""
        CLICKHOUSE_PASSWORD            = ""
        CLICKHOUSE_DATABASE            = ""
        ENVIRONMENT                   = "${environment}"
        POSTHOG_API_KEY               = "posthog_api_key"
        ANALYTICS_COLLECTOR_HOST      = "analytics_collector_host"
        ANALYTICS_COLLECTOR_API_TOKEN = "analytics_collector_api_token"
        LOKI_ADDRESS                  = "http://loki.service.consul:3100"
        OTEL_TRACING_PRINT            = "false"
        LOGS_COLLECTOR_ADDRESS        = "http://localhost:30006"
        NOMAD_ADDRESS                 = "https://localhost:4646"
        NOMAD_CACERT                  = "/opt/nomad/tls/ca.pem"
        NOMAD_CLIENT_CERT             = "/opt/nomad/tls/cert.pem"
        NOMAD_CLIENT_KEY              = "/opt/nomad/tls/key.pem"
        OTEL_COLLECTOR_GRPC_ENDPOINT  = "localhost:4317"
        REDIS_URL                     = "${REDIS_ENDPOINT}:6379"
        DNS_PORT                      = 5353
        # This is here just because it is required in some part of our code which is transitively imported
        TEMPLATE_BUCKET_NAME          = "skip"
        BUILD_CONTEXT_BUCKET_NAME     = "${BUCKET_DOCKER_CONTEXTS}"
      }

      template {
        data = <<EOH
POSTGRES_CONNECTION_STRING={{ file "/opt/e2b/secrets/postgres_connection_string" }}
DB_HOST={{ file "/opt/e2b/secrets/postgres_host" }}
DB_USER={{ file "/opt/e2b/secrets/postgres_user" }}
DB_PASSWORD={{ file "/opt/e2b/secrets/postgres_password" }}
NOMAD_TOKEN={{ file "/opt/e2b/secrets/nomad_acl_token" }}
CONSUL_HTTP_TOKEN={{ file "/opt/e2b/secrets/consul_http_token" }}
ADMIN_TOKEN={{ file "/opt/e2b/secrets/admin_token" }}
SANDBOX_ACCESS_TOKEN_HASH_SEED={{ file "/opt/e2b/secrets/sandbox_access_token_hash_seed" }}
EOH
        destination = "secrets/secrets.env"
        env         = true
        change_mode = "restart"
        perms       = "400"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/api:${IMAGE_TAG}"
        ports        = ["api"]
        args         = [
          "--port", "50001",
        ]
        volumes = [
          "/opt/nomad/tls:/opt/nomad/tls:ro"
        ]
      }
    }
  }
}
