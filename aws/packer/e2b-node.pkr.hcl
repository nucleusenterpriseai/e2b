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
  default = "us-east-1"
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "ami_name_prefix" {
  type    = string
  default = "e2b-node"
}

variable "volume_size" {
  type    = number
  default = 100
}

source "amazon-ebs" "e2b" {
  ami_name      = "${var.ami_name_prefix}-{{timestamp}}"
  instance_type = var.instance_type
  region        = var.region

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/*ubuntu-jammy-22.04-amd64-server-*"
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
    iops                  = 3000
    throughput            = 125
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.ami_name_prefix}-{{timestamp}}"
    Builder = "packer"
    Project = "e2b"
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
    inline = [
      "echo '==> Installing AWS CLI v2'",
      "curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip",
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
  }

  # Install CNI plugins
  provisioner "shell" {
    script = "setup/install-cni.sh"
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
