#!/bin/bash
# ============================================================
# Pterodactyl Panel + Wings Installer
# Run this MANUALLY via SSH after mc_init.sh completes
# Usage: sudo bash install_pterodactyl.sh
# ============================================================
set -euo pipefail

# ── Config (change these before running) ──────────────────────────────────
PANEL_USER="admin"
PANEL_EMAIL="admin@example.com"
PANEL_PASSWORD="changeme123"          # Change this!
DB_PASSWORD=$(openssl rand -hex 16)   # Auto-generated

# ── Detect public IP for Panel URL ────────────────────────────────────────
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
APP_URL="http://${PUBLIC_IP}:8080"

echo "======================================================"
echo " Pterodactyl Panel Installer"
echo " Panel URL: ${APP_URL}"
echo "======================================================"

# ── 1. Install dependencies ────────────────────────────────────────────────
apt-get update -y
apt-get install -y software-properties-common curl apt-transport-https ca-certificates

# PHP 8.3
add-apt-repository -y ppa:ondrej/php
apt-get update -y
apt-get install -y \
  php8.3 php8.3-cli php8.3-gd php8.3-mysql php8.3-pdo php8.3-mbstring \
  php8.3-tokenizer php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl \
  php8.3-zip php8.3-intl php8.3-redis

# Nginx, MariaDB, Redis
apt-get install -y nginx mariadb-server redis-server

# Node.js 20 (for panel assets)
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

# Composer
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# ── 2. Setup MariaDB ───────────────────────────────────────────────────────
systemctl start mariadb
systemctl enable mariadb

mysql -e "CREATE DATABASE IF NOT EXISTS panel;"
mysql -e "CREATE USER IF NOT EXISTS 'pterodactyl'@'127.0.0.1' IDENTIFIED BY '${DB_PASSWORD}';"
mysql -e "GRANT ALL PRIVILEGES ON panel.* TO 'pterodactyl'@'127.0.0.1' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

# Save DB password for reference
echo "DB_PASSWORD=${DB_PASSWORD}" > /root/.ptero_db_pass
chmod 600 /root/.ptero_db_pass

# ── 3. Download Panel ──────────────────────────────────────────────────────
mkdir -p /var/www/pterodactyl
cd /var/www/pterodactyl
curl -Lo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
tar -xzf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
rm panel.tar.gz

# ── 4. Configure environment ───────────────────────────────────────────────
cp .env.example .env

composer install --no-dev --optimize-autoloader --no-interaction

php artisan key:generate --force

# Set environment values
php artisan p:environment:setup \
  --author="${PANEL_EMAIL}" \
  --url="${APP_URL}" \
  --timezone="Asia/Hong_Kong" \
  --cache=redis \
  --session=redis \
  --queue=redis \
  --redis-host=127.0.0.1 \
  --redis-pass=null \
  --redis-port=6379

php artisan p:environment:database \
  --host=127.0.0.1 \
  --port=3306 \
  --database=panel \
  --username=pterodactyl \
  --password="${DB_PASSWORD}"

# ── 5. Run migrations ──────────────────────────────────────────────────────
php artisan migrate --seed --force

# ── 6. Create admin user ───────────────────────────────────────────────────
php artisan p:user:make \
  --email="${PANEL_EMAIL}" \
  --username="${PANEL_USER}" \
  --name-first="Admin" \
  --name-last="User" \
  --password="${PANEL_PASSWORD}" \
  --admin=1

# ── 7. File permissions ────────────────────────────────────────────────────
chown -R www-data:www-data /var/www/pterodactyl/

# ── 8. Queue worker (cron) ─────────────────────────────────────────────────
(crontab -l -u www-data 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1") | crontab -u www-data -

# Queue worker systemd service
cat > /etc/systemd/system/pteroq.service << 'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable pteroq
systemctl start pteroq

# ── 9. Nginx on port 8080 ──────────────────────────────────────────────────
rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/pterodactyl.conf << NGINXEOF
server {
    listen 8080;
    server_name _;

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log  /var/log/nginx/pterodactyl.error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/

nginx -t
systemctl enable nginx
systemctl restart nginx php8.3-fpm

# ── 10. Install Docker + Wings ─────────────────────────────────────────────
echo "Installing Docker..."
curl -sSL https://get.docker.com/ | CHANNEL=stable sh
systemctl enable docker
systemctl start docker

mkdir -p /etc/pterodactyl
curl -L -o /usr/local/bin/wings \
  "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_amd64"
chmod u+x /usr/local/bin/wings

cat > /etc/systemd/system/wings.service << 'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl enable wings
# NOTE: Wings will not start until configured with Panel token (see steps below)
# After Wings config is generated, fix CORS for websocket access:
# This allows the browser to connect to Wings websocket from the Panel

# ── Done ───────────────────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " Pterodactyl Panel installed successfully!"
echo "======================================================"
echo " Panel URL  : ${APP_URL}"
echo " Login      : ${PANEL_EMAIL}"
echo " Password   : ${PANEL_PASSWORD}"
echo ""
echo " NEXT STEPS to connect Wings:"
echo " 1. Open Panel -> Admin -> Nodes -> Create Node"
echo "    - FQDN: ${PUBLIC_IP}"
echo "    - Daemon Port: 8443"
echo " 2. On the Node page, click 'Generate Token'"
echo " 3. Copy the config and run:"
echo "    sudo nano /etc/pterodactyl/config.yml   (paste config)"
echo ""
echo " 4. Fix CORS in Wings config (IMPORTANT):"
echo "    Add these lines at the bottom of /etc/pterodactyl/config.yml:"
echo "      allowed_origins:"
echo "        - \"${APP_URL}\""
echo "      allow_cors_private_network: true"
echo ""
echo " 5. Start Wings:"
echo "    sudo systemctl start wings"
echo ""
echo " 6. Create a Server in Panel (remember to set eula=true in Files)"
echo "======================================================"
