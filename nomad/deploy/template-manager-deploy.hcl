job "template-manager" {
  datacenters = ["us-west-2a", "us-west-2b"]
  node_pool  = "default"
  priority = 70

  group "template-manager" {
    network {
      port "template-manager" {
        static = "5009"
      }
    }
    service {
      name = "template-manager"
      port = "template-manager"

      check {
        type         = "grpc"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
        grpc_use_tls = false
        port         = "template-manager"
      }
    }

    task "start" {
      driver = "raw_exec"

      resources {
        memory     = 1024
        cpu        = 256
      }

      env {
        NODE_ID                      = "$${node.unique.name}"
        AWS_ACCOUNT_ID               = "269562551342"
        STORAGE_PROVIDER             = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER  = "AWS_ECR"
        AWS_DOCKER_REPOSITORY_NAME   = "e2bdev/base"
        AWS_REGION                   = "us-west-2"
        AWS_ECR_REPOSITORY           = "e2bdev/base"
        OTEL_TRACING_PRINT           = false
        ENVIRONMENT                  = "dev"
        TEMPLATE_AWS_BUCKET_NAME     = "e2b-dev-fc-template-269562551342"
        TEMPLATE_BUCKET_NAME         = "e2b-dev-fc-template-269562551342"
        BUILD_CONTEXT_BUCKET_NAME    = "e2b-dev-docker-contexts-269562551342"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        ORCHESTRATOR_SERVICES        = "template-manager"
      }

      template {
        data = <<EOH
CONSUL_TOKEN={{ file "/opt/e2b/secrets/consul_http_token" }}
EOH
        destination = "secrets/secrets.env"
        env         = true
        change_mode = "restart"
        perms       = "400"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/template-manager && local/template-manager --port 5009  --proxy-port 15007"]
      }

      artifact {
        source      = "s3://software-e2b-dev-us-west-2-269562551342.s3.us-west-2.amazonaws.com/template-manager"
      }
    }
  }
}
