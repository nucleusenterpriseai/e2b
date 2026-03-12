job "orchestrator" {
  datacenters = ["dc1"]
  type        = "system"

  constraint {
    attribute = "${node.class}"
    value     = "client"
  }

  update {
    max_parallel = 1
    stagger      = "30s"
  }

  group "orchestrator" {
    network {
      port "grpc" {
        static = 5008
      }
      port "proxy" {
        static = 5007
      }
    }

    restart {
      attempts = 3
      interval = "10m"
      delay    = "30s"
      mode     = "delay"
    }

    service {
      name = "e2b-orchestrator"
      port = "grpc"

      tags = [
        "e2b",
        "orchestrator",
        "grpc",
      ]

      check {
        name     = "orchestrator-grpc-health"
        type     = "tcp"
        interval = "10s"
        timeout  = "3s"

        check_restart {
          limit           = 3
          grace           = "120s"
          ignore_warnings = false
        }
      }
    }

    service {
      name = "e2b-orchestrator-proxy"
      port = "proxy"

      tags = [
        "e2b",
        "orchestrator",
        "proxy",
      ]

      check {
        name     = "orchestrator-proxy-health"
        type     = "tcp"
        interval = "10s"
        timeout  = "3s"
      }
    }

    task "orchestrator" {
      # raw_exec is required because the orchestrator needs direct access to:
      # - /dev/kvm for Firecracker VM creation
      # - TAP network interfaces
      # - iptables for VM networking
      # - cgroups for resource management
      driver = "raw_exec"

      config {
        command = "/opt/e2b/orchestrator"
      }

      # Artifact: download the orchestrator binary from S3
      artifact {
        source      = "s3::https://s3.amazonaws.com/${E2B_ARTIFACTS_BUCKET}/orchestrator/orchestrator"
        destination = "/opt/e2b/orchestrator"
        mode        = "file"
      }

      # Environment variables from Consul KV
      template {
        data        = <<-EOT
          {{- range ls "e2b/config/orchestrator" }}
          {{ .Key }}={{ .Value }}
          {{- end }}
        EOT
        destination = "secrets/orchestrator.env"
        env         = true
        change_mode = "restart"
      }

      env {
        # gRPC port
        GRPC_PORT = "${NOMAD_PORT_grpc}"

        # Proxy port for sandbox HTTP traffic
        PROXY_PORT = "${NOMAD_PORT_proxy}"

        # Services to run (orchestrator + template-manager on client nodes)
        ORCHESTRATOR_SERVICES = "orchestrator,template-manager"

        # Storage provider for templates/snapshots
        STORAGE_PROVIDER = "AWSBucket"

        # Node identification
        NODE_ID = "${node.unique.id}"
        NODE_IP = "${attr.unique.network.ip-address}"
      }

      resources {
        cpu    = 4000
        memory = 8192
      }
    }
  }
}
