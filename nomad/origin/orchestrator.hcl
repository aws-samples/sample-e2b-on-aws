job "orchestrator" {
  type = "system"
  node_pool  = "default"
  datacenters = ["${aws_az1}", "${aws_az2}"]

  priority = 90

  group "client-orchestrator" {
    network {
      port "orchestrator" {
        static = "5008"
      }
    }

    service {
      name = "orchestrator"
      port = "orchestrator"

      check {
        type         = "grpc"
        name         = "health"
        interval     = "20s"
        timeout      = "5s"
        grpc_use_tls = false
        port         = "orchestrator"
      }
    }

    task "start" {
      driver = "raw_exec"

      env {
        NODE_ID                      = "${node.unique.id}"
        NODE_IP                      = "${attr.unique.network.ip-address}"
        CONSUL_TOKEN                 = "${consul_http_token}"
        OTEL_TRACING_PRINT           = false
        LOGS_COLLECTOR_ADDRESS       = "http://localhost:30006"
        ENVIRONMENT                  = "${environment}"
        TEMPLATE_BUCKET_NAME         = "${BUCKET_E2B}"
        TEMPLATE_BUCKET_PREFIX       = "fc-templates/"
        BUILD_CACHE_BUCKET_NAME      = "${BUCKET_E2B}"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        AWS_REGION                   = "${AWSREGION}"
        STORAGE_PROVIDER             = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER  = "AWS_ECR"
        ORCHESTRATOR_SERVICES        = "orchestrator"
        REDIS_CLUSTER_URL                    = "${REDIS_ENDPOINT}:6379"
        REDIS_TLS_ENABLED                = "true"
        REDIS_TLS_CA_BASE64          = ""
        DOMAIN_NAME                  = "${CFNDOMAIN}"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", "chmod +x local/orchestrator && local/orchestrator"]
      }

      artifact {
        source = "s3://${CFNE2BBUCKET}.s3.${AWSREGION}.amazonaws.com/software/orchestrator"
      }
    }
  }
}
