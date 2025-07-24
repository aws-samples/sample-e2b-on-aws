packer {
  required_version = ">=1.8.4"
  required_plugins {
    amazon = {
      version = "1.2.6"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

source "amazon-ebs" "orch" {
  ami_name      = "e2b-ubuntu-ami-${formatdate("YYYY-MM-DD-hh-mm-ss", timestamp())}"
  instance_type = var.architecture == "x86_64" ? "t3.xlarge" : "t4g.xlarge"
  region        = var.aws_region

  source_ami_filter {
     filters = {
       name = var.architecture == "x86_64" ? "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" : "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
       root-device-type    = "ebs"
       virtualization-type = "hvm"
       state               = "available"
       architecture        = var.architecture
     }
    owners = ["amazon"] // 或实际拥有此 AMI 的 AWS 账户 ID
    most_recent = true
  }
  
  ssh_username = "ubuntu"
  
  # Enable nested virtualization
  ami_virtualization_type = "hvm"
  
  # Use EBS for the root volume
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 10
    volume_type           = "gp3"
    delete_on_termination = true
  }
}

build {
  sources = [
    "source.amazon-ebs.orch"
  ]

  provisioner "shell" {
    inline = [
      "sudo apt-get clean",
      "sudo apt-get update -y",
      "sudo apt-get upgrade -y",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git"
    ]
  }
  
  provisioner "file" {
    source      = "${path.root}/setup/supervisord.conf"
    destination = "/tmp/supervisord.conf"
  }

  provisioner "file" {
    source      = "${path.root}/setup"
    destination = "/tmp"
  }

  provisioner "file" {
    source      = "${path.root}/setup/daemon.json"
    destination = "/tmp/daemon.json"
  }

  provisioner "file" {
    source      = "${path.root}/setup/limits.conf"
    destination = "/tmp/limits.conf"
  }

  # Install Docker
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/docker",
      "sudo mv /tmp/daemon.json /etc/docker/daemon.json",
      "sudo curl -fsSL https://get.docker.com -o get-docker.sh",
      "sudo sh get-docker.sh",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y unzip jq net-tools qemu-utils make build-essential openssh-client openssh-server", # TODO: openssh-server is updated to prevent security vulnerabilities
    ]
  }
  
  provisioner "shell" {
    only = ["amazon-ebs.orch"]
    inline = [
      "sudo apt-get update && sudo apt-get upgrade -y",
      "if [ \"${var.architecture}\" = \"x86_64\" ]; then",
      "  sudo curl 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'",
      "else",
      "  sudo curl 'https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip' -o 'awscliv2.zip'",
      "fi",
      "sudo apt-get install -y zip",
      "sudo unzip awscliv2.zip",
      "sudo ./aws/install",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y s3fs-fuse || echo 'Failed to install s3fs-fuse'",
      "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y s3fs || echo 'Failed to install s3fs'"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo DEBIAN_FRONTEND=noninteractive snap install go --classic"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo systemctl start docker",
      "sudo usermod -aG docker $USER",
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/gruntwork",
      "git clone --branch v0.1.3 https://github.com/gruntwork-io/bash-commons.git /tmp/bash-commons",
      "sudo cp -r /tmp/bash-commons/modules/bash-commons/src /opt/gruntwork/bash-commons",
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/setup/install-consul.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.consul_version}"
  }

  provisioner "shell" {
    script          = "${path.root}/setup/install-nomad.sh"
    execute_command = "chmod +x {{ .Path }}; {{ .Vars }} {{ .Path }} --version ${var.nomad_version}"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/nomad/plugins",
    ]
  }
  
  provisioner "shell" {
    only = ["amazon-ebs.orch"]
    inline = [
      "sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/bin/",
      "if [ \"${var.architecture}\" = \"x86_64\" ]; then",
      "  sudo wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb",
      "else",
      "  sudo wget https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb",
      "fi",
      "sudo dpkg -i /tmp/amazon-cloudwatch-agent.deb || sudo DEBIAN_FRONTEND=noninteractive apt-get install -f -y",
      "sudo systemctl enable amazon-cloudwatch-agent"
    ]
  }

  provisioner "shell" {
    inline = [
      # Increase the maximum number of open files
      "sudo mv /tmp/limits.conf /etc/security/limits.conf",
      # Increase the maximum number of connections by 4x
      "echo 'net.netfilter.nf_conntrack_max = 2097152' | sudo tee -a /etc/sysctl.conf",
    ]
  }
}
