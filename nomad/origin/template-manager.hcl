job "template-manager" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
  node_pool  = "build"
  priority = 70

  group "template-manager" {
    network {
      port "template-manager" {
        static = "5008"
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
        NODE_ID                       = "$${node.unique.name}"
        NODE_IP                       = "$${attr.unique.network.ip-address}"
        CONSUL_TOKEN                  = "${consul_http_token}"
        STORAGE_PROVIDER              = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER   = "AWS_ECR"
        AWS_REGION                    = "${AWSREGION}"
        OTEL_TRACING_PRINT            = false
        ENVIRONMENT                   = "dev"
        TEMPLATE_BUCKET_NAME          = "${BUCKET_E2B}"
        TEMPLATE_BUCKET_PREFIX        = "fc-templates/"
        BUILD_CACHE_BUCKET_NAME       = "${BUCKET_E2B}"
        OTEL_COLLECTOR_GRPC_ENDPOINT  = "localhost:4317"
        ORCHESTRATOR_SERVICES         = "template-manager"
        AWS_DOCKER_REPOSITORY_NAME    = "e2bdev/base"
        REDIS_CLUSTER_URL                     = "${REDIS_ENDPOINT}:6379"
        REDIS_TLS_ENABLED                = "true"
        REDIS_TLS_CA_BASE64          = ""
        DOMAIN_NAME                   = "${CFNDOMAIN}"
        GRPC_PORT                     = "5008"
        PROXY_PORT                    = "5007"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", "chmod +x local/template-manager && local/template-manager"]
      }

      artifact {
        source      = "s3://${CFNE2BBUCKET}.s3.${AWSREGION}.amazonaws.com/software/template-manager"
      }
    }
  }
}
