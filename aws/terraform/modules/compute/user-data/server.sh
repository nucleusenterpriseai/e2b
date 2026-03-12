#!/usr/bin/env bash
set -euo pipefail

# --- Set hostname ---
INSTANCE_ID=$(ec2-metadata -i | awk '{print $2}')
hostnamectl set-hostname "${prefix}-server-$${INSTANCE_ID}"

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
NODE_ROLE=server
ENVIRONMENT=${environment}
DOMAIN=${domain}
PREFIX=${prefix}
SERVER_COUNT=${server_count}
CONSUL_TOKEN=$${CONSUL_TOKEN}
NOMAD_TOKEN=$${NOMAD_TOKEN}
GOSSIP_KEY=$${GOSSIP_KEY}
AWS_REGION=${region}
EOF

chmod 600 /opt/e2b/config.env

# --- Generate Consul server configuration ---
mkdir -p /etc/consul.d
cat > /etc/consul.d/consul.hcl <<EOF
datacenter = "dc1"
data_dir   = "/opt/consul/data"
log_level  = "INFO"

server           = true
bootstrap_expect = ${server_count}

bind_addr      = "$${PRIVATE_IP}"
advertise_addr = "$${PRIVATE_IP}"
client_addr    = "0.0.0.0"

# AWS tag-based auto-join for cluster formation
retry_join = ["provider=aws tag_key=Role tag_value=server region=${region}"]

encrypt = "$${GOSSIP_KEY}"

acl {
  enabled                  = true
  default_policy           = "deny"
  enable_token_persistence = true

  tokens {
    initial_management = "$${CONSUL_TOKEN}"
    agent              = "$${CONSUL_TOKEN}"
  }
}

ui_config {
  enabled = true
}

performance {
  raft_multiplier = 1
}
EOF

chmod 640 /etc/consul.d/consul.hcl

# --- Generate Nomad server configuration ---
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

server {
  enabled          = true
  bootstrap_expect = ${server_count}

  server_join {
    retry_join = ["provider=aws tag_key=Role tag_value=server region=${region}"]
  }
}

consul {
  address = "127.0.0.1:8500"
  token   = "$${CONSUL_TOKEN}"
}

acl {
  enabled = true
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
EOF

chmod 640 /etc/nomad.d/nomad.hcl

# --- Start Consul agent (server mode) ---
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

# --- Start Nomad agent (server mode) ---
systemctl enable nomad
systemctl start nomad

echo "Server node initialization complete."
