job "docker-reverse-proxy" {
  datacenters = ["us-west-2a", "us-west-2b"]
  node_pool = "api"
  priority = 85

  group "docker-reverse-proxy" {
    network {
      port "docker-reverse-proxy" {
        static = "5000"
      }
    }

    service {
      name = "docker-reverse-proxy"
      port = "docker-reverse-proxy"
      task = "start"

      check {
        type     = "http"
        name     = "health"
        path     = "/health"
        interval = "5s"
        timeout  = "5s"
        port     = "docker-reverse-proxy"
      }
    }

    task "start" {
      driver = "docker"

      resources {
        memory_max = 2048
        memory = 512
        cpu    = 256
      }

      env {
        # POSTGRES_CONNECTION_STRING = "postgresql://e2badmin@e2b-dev-e2b-aurora-db.cluster-cldxbe3nbhn3.us-west-2.rds.amazonaws.com/e2b"
        # CFNDBURL = "postgresql://e2badmin@e2b-dev-e2b-aurora-db.cluster-cldxbe3nbhn3.us-west-2.rds.amazonaws.com/e2b"
        # AWS_REGION                 = "us-west-2"
        # AWS_ACCOUNT_ID             = "269562551342"
        # AWS_ECR_REPOSITORY         = "e2bdev/base"
        # DOMAIN_NAME                = "e2b-dev.internal"
        # LOG_LEVEL                  = "debug"

        CLOUD_PROVIDER             =   "aws"
        DOMAIN_NAME                = "e2b-dev.internal"
        AWS_REGION                 = "us-west-2"
        AWS_ECR_REPOSITORY_NAME    = "e2bdev/base"
        LOG_LEVEL                  = "debug"
      }

      template {
        data = <<EOH
POSTGRES_CONNECTION_STRING={{ file "/opt/e2b/secrets/postgres_connection_string" }}
EOH
        destination = "secrets/secrets.env"
        env         = true
        change_mode = "restart"
        perms       = "400"
      }

      config {
        network_mode = "host"
        dns_servers  = ["127.0.0.53"]
        image        = "269562551342.dkr.ecr.us-west-2.amazonaws.com/e2b-orchestration/docker-reverse-proxy:c4ca593"
        ports        = ["docker-reverse-proxy"]
        args         = ["--port", "5000"]
        force_pull   = true
      }
    }
  }
}
