job "api" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool = "api"
  priority = 90

  group "api-service" {
    network {
      port "api" {
        static = "50001"
      }
      port "dns" {
        static = "5353"
      }
    }

    constraint {
      operator  = "distinct_hosts"
      value     = "true"
    }

    service {
      name = "api"
      port = "api"
      task = "start"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "3s"
        timeout  = "3s"
        port     = "api"
      }
    }



    task "start" {
      driver       = "docker"
      # If we need more than 30s we will need to update the max_kill_timeout in nomad
      # https://developer.hashicorp.com/nomad/docs/configuration/client#max_kill_timeout
      kill_timeout = "30s"
      kill_signal  = "SIGTERM"

      resources {
        memory_max = 4096
        memory     = 2048
        cpu        = 2000
      }

      env {
        ORCHESTRATOR_PORT             = 5008
        TEMPLATE_MANAGER_HOST         = "template-manager.service.consul:5009"
        AWS_ENABLED                   = "true"
        POSTGRES_CONNECTION_STRING    = "${CFNDBURL}"
        SUPABASE_JWT_SECRETS          = "${CFNDBURL}"
        CLICKHOUSE_CONNECTION_STRING   = ""
        CLICKHOUSE_USERNAME            = ""
        CLICKHOUSE_PASSWORD            = ""
        CLICKHOUSE_DATABASE            = ""
        DB_HOST                       = "${postgres_host}"
        DB_USER                       = "${postgres_user}"
        DB_PASSWORD                   = "${postgres_password}"
        ENVIRONMENT                   = "${environment}"
        POSTHOG_API_KEY               = "posthog_api_key"
        ANALYTICS_COLLECTOR_HOST      = "analytics_collector_host"
        ANALYTICS_COLLECTOR_API_TOKEN = "analytics_collector_api_token"
        LOKI_ADDRESS                  = "http://loki.service.consul:3100"
        OTEL_TRACING_PRINT            = "false"
        LOGS_COLLECTOR_ADDRESS        = "http://localhost:30006"
        NOMAD_TOKEN                   = "${nomad_acl_token}"
        CONSUL_HTTP_TOKEN             = "${consul_http_token}"
        OTEL_COLLECTOR_GRPC_ENDPOINT  = "localhost:4317"
        ADMIN_TOKEN                   = "${admin_token}"
        REDIS_URL                     = "${REDIS_ENDPOINT}:6379"
        DNS_PORT                      = 5353
        # This is here just because it is required in some part of our code which is transitively imported
        TEMPLATE_BUCKET_NAME          = "skip"
      }

      config {
        network_mode = "host"
        image        = "${account_id}.dkr.ecr.${AWSREGION}.amazonaws.com/e2b-orchestration/api:latest"
        ports        = ["api", "dns"]
        args         = [
          "--port", "50001",
        ]
      }
    }
  }
}
