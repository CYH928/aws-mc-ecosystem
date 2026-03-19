resource "aws_security_group" "watcher" {
  name        = "mc-watcher-sg"
  description = "Minecraft watcher - always on, accepts all player connections"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Minecraft players"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Web control panel for admin
  ingress {
    description = "MC Web Control Panel"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mc-watcher-sg" }
}

resource "aws_security_group" "minecraft" {
  name        = "mc-server-sg"
  description = "Minecraft main server - only watcher can reach game port"
  vpc_id      = data.aws_vpc.default.id

  # Game port: only from watcher (players never connect directly)
  ingress {
    description     = "Minecraft from watcher proxy"
    from_port       = 25565
    to_port         = 25565
    protocol        = "tcp"
    security_groups = [aws_security_group.watcher.id]
  }

  # RCON: from watcher only (for player count, graceful stop)
  ingress {
    description     = "RCON from watcher"
    from_port       = 25575
    to_port         = 25575
    protocol        = "tcp"
    security_groups = [aws_security_group.watcher.id]
  }

  ingress {
    description = "SSH admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Pterodactyl Panel web UI
  ingress {
    description = "Pterodactyl Panel HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Pterodactyl Wings API + WebSocket (browser connects directly)
  ingress {
    description = "Pterodactyl Wings API"
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "mc-server-sg" }
}
