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
  vpc_id        = var.vpc_id
  subnet_id     = var.subnet_id

  source_ami = var.custom_ami_id

  ssh_username = "ubuntu"

  # Enable nested virtualization
  ami_virtualization_type = "hvm"

  # Force IMDSv2
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Tags for the temporary instance and AMI
  tags = {
    team        = "GenAI"
    service     = "GenAI"
    owner       = "GenAI"
    cost_center = "GenAI"
    component   = "GenAI"
    Image-Type  = "GoldenImage"
  }

  # Tags for the temporary instance only
  run_tags = {
    team        = "GenAI"
    service     = "GenAI"
    owner       = "GenAI"
    cost_center = "GenAI"
    component   = "GenAI"
  }

  # Use EBS for the root volume with encryption
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }
}

build {
  sources = [
    "source.amazon-ebs.orch"
  ]

  provisioner "shell" {
      execute_command = "sudo -E bash '{{ .Path }}'"
    inline = [
      "sudo mount -o remount,exec /tmp",
      "echo 'web' | sudo tee /var/lib/teleport/team > /dev/null && sudo chown root:root /var/lib/teleport/team && sudo chmod 0644 /var/lib/teleport/team",
      "echo 'Waiting for cloud-init to finish...'",
      "cloud-init status --wait || true",
      "echo 'Stopping auto-update services...'",
      "sudo systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true",
      "sudo systemctl kill apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true",
      "sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer || true",
      "sudo systemctl mask apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true",
      "sudo killall -9 apt-get apt dpkg unattended-upgr 2>/dev/null || true",
      "echo 'Waiting for apt/dpkg locks to be released...'",
      "for i in $(seq 1 60); do if sudo fuser /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then echo \"Lock held, waiting... ($i/60)\"; sleep 5; else echo 'Locks released.'; break; fi; done",
      "sleep 5"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "DEBCONF_NONINTERACTIVE_SEEN=true"
    ]
    inline = [
      "sudo -E apt-get clean",
      "sudo -E apt-get update -y",
      "sudo -E apt-get upgrade -y",
      "sudo -E apt-get install -y ca-certificates curl git rsync"
    ]
  }

  # Ensure systemd-resolved is active and /etc/resolv.conf uses the stub resolver (127.0.0.53)
  provisioner "shell" {
    inline = [
      "sudo systemctl enable systemd-resolved",
      "sudo systemctl start systemd-resolved",
      "sudo ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
    ]
  }

  # Install AWS-optimized kernel and update GRUB configuration
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "DEBCONF_NONINTERACTIVE_SEEN=true"
    ]
    inline = [
      "sudo -E apt-get install -y linux-aws",
      "blkid -L cloudimg-rootfs | xargs blkid -s PARTUUID -o value | awk '{print \"GRUB_FORCE_PARTUUID=\"$1}' | sudo tee /etc/default/grub.d/40-force-partuuid.cfg > /dev/null",
      "sudo chmod 755 /etc/default/grub.d/40-force-partuuid.cfg",
      "sudo update-grub",
      "sudo update-initramfs -u -k all"
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
      "sudo sh get-docker.sh"
    ]
  }

  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "DEBCONF_NONINTERACTIVE_SEEN=true"
    ]
    inline = [
      "sudo -E apt-get update",
      "sudo -E apt-get install -y unzip jq net-tools qemu-utils make build-essential openssh-client openssh-server" # TODO: openssh-server is updated to prevent security vulnerabilities
    ]
  }
  
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "DEBCONF_NONINTERACTIVE_SEEN=true"
    ]
    only = ["amazon-ebs.orch"]
    inline = [
      "sudo -E apt-get update && sudo -E apt-get upgrade -y",
      "curl -s -o /tmp/aws-cli-public-key.asc 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xFB5DB77FD5C118B80511ADA8A6310ACC4672475C'",
      "gpg --import /tmp/aws-cli-public-key.asc",
      "if [ \"${var.architecture}\" = \"x86_64\" ]; then",
      "  curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o 'awscliv2.zip'",
      "  curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip.sig' -o 'awscliv2.zip.sig'",
      "else",
      "  curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip' -o 'awscliv2.zip'",
      "  curl -s 'https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip.sig' -o 'awscliv2.zip.sig'",
      "fi",
      "gpg --verify awscliv2.zip.sig awscliv2.zip",
      "sudo -E apt-get install -y zip",
      "sudo unzip awscliv2.zip",
      "sudo ./aws/install",
      "sudo -E apt-get install -y s3fs-fuse || echo 'Failed to install s3fs-fuse'",
      "sudo -E apt-get install -y s3fs || echo 'Failed to install s3fs'"
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
      "sudo usermod -aG docker $USER"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/gruntwork",
      "git clone https://github.com/gruntwork-io/bash-commons.git /tmp/bash-commons",
      "git -C /tmp/bash-commons checkout 013a0b429d0bd57ce49f487fade15cf95cef5b6d",
      "sudo cp -r /tmp/bash-commons/modules/bash-commons/src /opt/gruntwork/bash-commons",
      "sudo chmod -R a+rX /opt/gruntwork"
    ]
  }

  provisioner "shell" {
    script          = "${path.root}/setup/install-consul.sh"
    execute_command =  "chmod +x {{ .Path }}; {{ .Vars }} sudo bash  {{ .Path }} --version ${var.consul_version}"
  }

  provisioner "shell" {
    script          = "${path.root}/setup/install-nomad.sh"
    execute_command =  "chmod +x {{ .Path }}; {{ .Vars }} sudo bash {{ .Path }} --version ${var.nomad_version}"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/nomad/plugins",
    ]
  }
  
  provisioner "shell" {
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "DEBCONF_NONINTERACTIVE_SEEN=true"
    ]    
    only = ["amazon-ebs.orch"]
    inline = [
      "sudo mkdir -p /opt/aws/amazon-cloudwatch-agent/bin/",
      "wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/assets/amazon-cloudwatch-agent.gpg -O /tmp/cw-agent.gpg",
      "gpg --import /tmp/cw-agent.gpg",
      "if [ \"${var.architecture}\" = \"x86_64\" ]; then",
      "  wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb",
      "  wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb.sig -O /tmp/amazon-cloudwatch-agent.deb.sig",
      "else",
      "  wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb -O /tmp/amazon-cloudwatch-agent.deb",
      "  wget -q https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb.sig -O /tmp/amazon-cloudwatch-agent.deb.sig",
      "fi",
      "gpg --verify /tmp/amazon-cloudwatch-agent.deb.sig /tmp/amazon-cloudwatch-agent.deb",
      "sudo dpkg -i /tmp/amazon-cloudwatch-agent.deb || sudo -E apt-get install -f -y",
      "sudo systemctl enable amazon-cloudwatch-agent"
    ]
  }

  provisioner "shell" {
    inline = [
      "sudo snap install amazon-ssm-agent --classic",
      "sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service",
      "sudo systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service"
    ]
  }

  provisioner "shell" {
    inline = [
      # Increase the maximum number of open files
      "sudo mv /tmp/limits.conf /etc/security/limits.conf",
      # Increase the maximum number of connections by 4x
      "echo 'net.netfilter.nf_conntrack_max = 2097152' | sudo tee -a /etc/sysctl.conf",
      "sudo systemctl disable apt-daily.timer apt-daily-upgrade.timer || true",
      "sudo systemctl mask apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true"
    ]
  }
}