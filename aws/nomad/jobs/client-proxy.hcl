job "client-proxy" {
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

  group "proxy" {
    count = 1

    network {
      port "proxy" {
        static = 3002
      }
      port "health" {
        static = 3003
      }
    }

    restart {
      attempts = 5
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    service {
      name = "e2b-client-proxy"
      port = "proxy"

      tags = [
        "e2b",
        "client-proxy",
        "http",
      ]

      check {
        name     = "client-proxy-health"
        type     = "http"
        port     = "health"
        path     = "/"
        interval = "10s"
        timeout  = "3s"

        check_restart {
          limit           = 3
          grace           = "60s"
          ignore_warnings = false
        }
      }
    }

    service {
      name = "e2b-client-proxy-health"
      port = "health"

      tags = [
        "e2b",
        "client-proxy",
        "health",
      ]
    }

    task "client-proxy" {
      driver = "docker"

      config {
        image = "${ECR_REGISTRY}/e2b-orchestration/client-proxy:latest"
        ports = ["proxy", "health"]

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
          {{- range ls "e2b/config/client-proxy" }}
          {{ .Key }}={{ .Value }}
          {{- end }}
        EOT
        destination = "secrets/client-proxy.env"
        env         = true
        change_mode = "restart"
      }

      # Resolve API gRPC address via Consul service discovery
      template {
        data = <<-EOF
          {{ range service "e2b-api-grpc" }}
          API_GRPC_ADDRESS={{ .Address }}:{{ .Port }}
          {{ end }}
        EOF
        destination = "local/api.env"
        env         = true
        change_mode = "restart"
      }

      env {
        # Proxy port
        PROXY_PORT = "${NOMAD_PORT_proxy}"

        # Health check port
        HEALTH_PORT = "${NOMAD_PORT_health}"

        # Node identification
        NODE_ID = "${node.unique.id}"
      }

      resources {
        cpu    = 500
        memory = 1024
      }
    }
  }
}
