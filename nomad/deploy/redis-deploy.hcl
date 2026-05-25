job "redis" {
  datacenters = ["us-west-2a", "us-west-2b"]
  node_pool = "api"
  type = "service"
  priority = 95

  group "redis" {
    network {
      port "redis" {
        static = "6379"
      }
    }

    service {
      name = "redis"
      port = "redis"

      check {
        type    = "tcp"
        name    = "health"
        interval = "10s"
        timeout = "2s"
        port    = "redis"
      }
    }

    task "start" {
      driver = "docker"

      resources {
        memory_max = 4096
        memory    = 2048
        cpu      = 1000
      }

      config {
        network_mode = "host"
        image        = "artifactory.aic.aws.zoomdev.us/zoom-docker-virtual/redis:7.4.2-alpine"
        ports        = ["redis"]
        args = []
        auth_soft_fail = true
      }
    }
  }
}
