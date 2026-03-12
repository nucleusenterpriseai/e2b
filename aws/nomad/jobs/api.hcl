job "api" {
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

  group "api" {
    count = 1

    network {
      port "http" {
        static = 50001
      }
      port "grpc" {
        static = 5009
      }
    }

    restart {
      attempts = 5
      interval = "5m"
      delay    = "15s"
      mode     = "delay"
    }

    service {
      name = "e2b-api"
      port = "http"

      tags = [
        "e2b",
        "api",
        "http",
      ]

      check {
        name     = "api-health"
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

    service {
      name = "e2b-api-grpc"
      port = "grpc"

      tags = [
        "e2b",
        "api",
        "grpc",
      ]

      check {
        name     = "api-grpc-health"
        type     = "tcp"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "api" {
      driver = "docker"

      config {
        image = "${ECR_REGISTRY}/e2b-orchestration/api:latest"
        ports = ["http", "grpc"]

        # ECR auth via instance IAM role
        auth_soft_fail = true

        logging {
          type = "json-file"
          config {
            max-size = "50m"
            max-file = "3"
          }
        }
      }

      # Environment variables injected from Consul KV and Vault
      template {
        data        = <<-EOT
          {{- range ls "e2b/config/api" }}
          {{ .Key }}={{ .Value }}
          {{- end }}
        EOT
        destination = "secrets/api.env"
        env         = true
        change_mode = "restart"
      }

      # Core environment variables
      env {
        # HTTP port (default 80 in code, we use 50001 for ALB routing)
        PORT = "${NOMAD_PORT_http}"

        # gRPC port for client-proxy communication
        API_GRPC_PORT = "${NOMAD_PORT_grpc}"

        # Sandbox storage backend
        SANDBOX_STORAGE_BACKEND = "redis"

        # Node identification
        NODE_ID = "${node.unique.id}"
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
