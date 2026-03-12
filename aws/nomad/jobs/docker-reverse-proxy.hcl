job "docker-reverse-proxy" {
  datacenters = ["dc1"]
  type        = "service"

  constraint {
    attribute = "${node.class}"
    value     = "api"
  }

  update {
    max_parallel      = 1
    min_healthy_time  = "30s"
    healthy_deadline  = "5m"
    progress_deadline = "10m"
    auto_revert       = true
    canary            = 0
  }

  group "docker-proxy" {
    count = 1

    network {
      port "http" {
        static = 5000
      }
    }

    restart {
      attempts = 5
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    service {
      name = "e2b-docker-reverse-proxy"
      port = "http"

      tags = [
        "e2b",
        "docker-reverse-proxy",
        "http",
      ]

      check {
        name     = "docker-proxy-health"
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "3s"

        check_restart {
          limit           = 3
          grace           = "60s"
          ignore_warnings = false
        }
      }
    }

    task "docker-reverse-proxy" {
      driver = "docker"

      config {
        image = "${ECR_REGISTRY}/e2b-orchestration/docker-reverse-proxy:latest"
        ports = ["http"]
        args  = ["-port", "${NOMAD_PORT_http}"]

        auth_soft_fail = true

        logging {
          type = "json-file"
          config {
            max-size = "50m"
            max-file = "3"
          }
        }
      }

      # Environment variables from Consul KV
      template {
        data        = <<-EOT
          {{- range ls "e2b/config/docker-reverse-proxy" }}
          {{ .Key }}={{ .Value }}
          {{- end }}
        EOT
        destination = "secrets/docker-proxy.env"
        env         = true
        change_mode = "restart"
      }

      env {
        # Node identification
        NODE_ID = "${node.unique.id}"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
