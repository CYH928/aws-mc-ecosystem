# ── AMIs ──────────────────────────────────────────────────────────────────

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_ami" "ubuntu_amd64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Watcher (t4g.nano, always on) ─────────────────────────────────────────

resource "aws_instance" "watcher" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.watcher_instance_type
  key_name               = var.key_pair_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.watcher.id]
  iam_instance_profile   = aws_iam_instance_profile.watcher.name

  user_data = templatefile("${path.module}/scripts/watcher_init.sh", {
    duckdns_token     = var.duckdns_token
    duckdns_subdomain = var.duckdns_subdomain
    mc_private_ip     = local.mc_private_ip
    aws_region        = var.aws_region
    mc_version        = var.mc_version
  })

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = { Name = "minecraft-watcher" }
}

# ── Minecraft Server (t3.xlarge, starts/stops on demand) ──────────────────

resource "aws_instance" "minecraft" {
  ami                    = data.aws_ami.ubuntu_amd64.id
  instance_type          = var.mc_instance_type
  key_name               = var.key_pair_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.minecraft.id]
  iam_instance_profile   = aws_iam_instance_profile.minecraft.name

  # Fixed private IP so watcher always knows where to proxy traffic
  private_ip = local.mc_private_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = false
    tags                  = { Name = "minecraft-server-root" }
  }

  user_data = templatefile("${path.module}/scripts/mc_init.sh", {
    backup_bucket = var.backup_bucket_name
    aws_region    = var.aws_region
    mc_version    = var.mc_version
    rcon_password = var.rcon_password
  })

  lifecycle {
    ignore_changes = [user_data]
  }

  tags = { Name = "minecraft-server" }
}
