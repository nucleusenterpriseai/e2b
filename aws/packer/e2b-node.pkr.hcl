packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "architecture" {
  description = "Target CPU architecture: x86_64 or arm64"
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be x86_64 or arm64."
  }
}

variable "ami_name_prefix" {
  type    = string
  default = "e2b-node"
}

variable "volume_size" {
  type    = number
  default = 200
}

locals {
  ami_arch     = var.architecture == "arm64" ? "arm64" : "amd64"
  aws_cli_arch = var.architecture == "arm64" ? "aarch64" : "x86_64"
  build_type   = var.architecture == "arm64" ? "c6g.large" : "t3.large"
}

source "amazon-ebs" "e2b" {
  ami_name      = "${var.ami_name_prefix}-${local.ami_arch}-{{timestamp}}"
  instance_type = local.build_type
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-${local.ami_arch}-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  ssh_username = "ubuntu"

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.volume_size
    volume_type           = "gp3"
    iops                  = 6000
    throughput            = 400
    delete_on_termination = true
  }

  tags = {
    Name         = "${var.ami_name_prefix}-${local.ami_arch}-{{timestamp}}"
    Builder      = "packer"
    Project      = "e2b"
    Architecture = var.architecture
  }
}

build {
  sources = ["source.amazon-ebs.e2b"]

  # System updates
  provisioner "shell" {
    inline = [
      "echo '==> Updating system packages'",
      "sudo apt-get update -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget unzip jq software-properties-common apt-transport-https ca-certificates gnupg lsb-release",
    ]
  }

  # Install AWS CLI v2
  provisioner "shell" {
    environment_vars = [
      "AWS_CLI_ARCH=${local.aws_cli_arch}",
    ]
    inline = [
      "echo '==> Installing AWS CLI v2 ($AWS_CLI_ARCH)'",
      "curl -fsSL \"https://awscli.amazonaws.com/awscli-exe-linux-$${AWS_CLI_ARCH}.zip\" -o /tmp/awscliv2.zip",
      "unzip -q /tmp/awscliv2.zip -d /tmp",
      "sudo /tmp/aws/install",
      "rm -rf /tmp/aws /tmp/awscliv2.zip",
      "aws --version",
    ]
  }

  # Install Docker
  provisioner "shell" {
    script = "setup/install-docker.sh"
  }

  # Install Nomad
  provisioner "shell" {
    script = "setup/install-nomad.sh"
  }

  # Install Consul
  provisioner "shell" {
    script = "setup/install-consul.sh"
  }

  # Install Firecracker + Jailer
  provisioner "shell" {
    script = "setup/install-firecracker.sh"
    environment_vars = [
      "TARGET_ARCH=${var.architecture}",
    ]
  }

  # Install CNI plugins
  provisioner "shell" {
    script = "setup/install-cni.sh"
    environment_vars = [
      "TARGET_ARCH=${var.architecture}",
    ]
  }

  # System tuning
  provisioner "shell" {
    script = "setup/system-tuning.sh"
  }

  # Final cleanup
  provisioner "shell" {
    inline = [
      "echo '==> Cleaning up'",
      "sudo apt-get autoremove -y",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/*",
      "echo '==> Build complete'",
    ]
  }
}
