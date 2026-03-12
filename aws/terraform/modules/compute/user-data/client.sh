#!/usr/bin/env bash
set -euo pipefail

# --- Set hostname ---
INSTANCE_ID=$(ec2-metadata -i | awk '{print $2}')
hostnamectl set-hostname "${prefix}-client-$${INSTANCE_ID}"

# --- Get instance metadata ---
PRIVATE_IP=$(ec2-metadata --local-ipv4 | awk '{print $2}')

# --- Retrieve secrets from AWS Secrets Manager ---
export AWS_DEFAULT_REGION="${region}"

CONSUL_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "${consul_token_arn}" \
  --query SecretString --output text)

NOMAD_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "${nomad_token_arn}" \
  --query SecretString --output text)

GOSSIP_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "${gossip_key_arn}" \
  --query SecretString --output text)

# --- Write E2B config ---
mkdir -p /opt/e2b
cat > /opt/e2b/config.env <<EOF
NODE_ROLE=client
ENVIRONMENT=${environment}
DOMAIN=${domain}
PREFIX=${prefix}
CONSUL_TOKEN=$${CONSUL_TOKEN}
NOMAD_TOKEN=$${NOMAD_TOKEN}
GOSSIP_KEY=$${GOSSIP_KEY}
AWS_REGION=${region}
EOF

chmod 600 /opt/e2b/config.env

# --- Generate Consul client configuration ---
mkdir -p /etc/consul.d
cat > /etc/consul.d/consul.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/consul/data"
log_level  = "INFO"

server = false

bind_addr      = "$${PRIVATE_IP}"
advertise_addr = "$${PRIVATE_IP}"
client_addr    = "0.0.0.0"

# AWS tag-based auto-join to discover Consul servers
retry_join = ["provider=aws tag_key=Role tag_value=server region=${region}"]

encrypt = "$${GOSSIP_KEY}"

acl {
  enabled        = true
  default_policy = "deny"

  tokens {
    agent = "$${CONSUL_TOKEN}"
  }
}
EOF

chmod 640 /etc/consul.d/consul.hcl

# --- Generate Nomad client configuration ---
mkdir -p /etc/nomad.d
cat > /etc/nomad.d/nomad.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"

bind_addr = "0.0.0.0"

advertise {
  http = "$${PRIVATE_IP}"
  rpc  = "$${PRIVATE_IP}"
  serf = "$${PRIVATE_IP}"
}

client {
  enabled    = true
  node_class = "client"

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=server region=${region}"]
  }

  meta {
    "node_type" = "client"
  }

  # Enable raw_exec for Firecracker
  options = {
    "driver.raw_exec.enable" = "1"
  }
}

consul {
  address = "127.0.0.1:8500"
  token   = "$${CONSUL_TOKEN}"
}

acl {
  enabled = true
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

plugin "docker" {
  config {
    allow_privileged = true
    volumes {
      enabled = true
    }
    gc {
      image       = true
      image_delay = "10m"
    }
    # ECR auth is handled by the docker credential helper
    auth {
      config = "/root/.docker/config.json"
    }
  }
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
EOF

chmod 640 /etc/nomad.d/nomad.hcl

# --- Start Consul agent (client mode) ---
systemctl enable consul
systemctl start consul

# --- Wait for Consul to be ready before starting Nomad ---
for i in $(seq 1 30); do
  if consul members -token="$${CONSUL_TOKEN}" &>/dev/null; then
    break
  fi
  sleep 2
done

if ! consul members -token="$${CONSUL_TOKEN}" &>/dev/null; then
    echo "ERROR: Consul not ready after 60 seconds" >&2
    # Don't exit — let Nomad try to start anyway, it may recover
fi

# --- Start Nomad agent (client mode) ---
systemctl enable nomad
systemctl start nomad

echo "Client node initialization complete."
