job "template-manager" {
  datacenters = ["${aws_az1}", "${aws_az2}"]
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
        AWS_ACCOUNT_ID               = "${account_id}"
        STORAGE_PROVIDER             = "AWSBucket"
        ARTIFACTS_REGISTRY_PROVIDER  = "AWS_ECR"
        AWS_DOCKER_REPOSITORY_NAME   = "e2bdev/base"
        AWS_REGION                   = "${AWSREGION}"
        CONSUL_TOKEN                 = "${consul_http_token}"
        AWS_ECR_REPOSITORY           = "e2bdev/base"
        OTEL_TRACING_PRINT           = false
        ENVIRONMENT                  = "dev"
        TEMPLATE_AWS_BUCKET_NAME     = "${BUCKET_FC_TEMPLATE}"
        TEMPLATE_BUCKET_NAME         = "${BUCKET_FC_TEMPLATE}"
        OTEL_COLLECTOR_GRPC_ENDPOINT = "localhost:4317"
        ORCHESTRATOR_SERVICES        = "template-manager"
      }

      config {
        command = "/bin/bash"
        args    = ["-c", " chmod +x local/template-manager && local/template-manager --port 5009  --proxy-port 15007"]
      }

      artifact {
        source      = "s3://${CFNSOFTWAREBUCKET}.s3.${AWSREGION}.amazonaws.com/template-manager"
      }
    }
  }
}
