#!/usr/bin/env bash
# Deploy pychess-variants behind nginx with a Let's Encrypt certificate (Debian/Ubuntu).
#
# Usage:  sudo DOMAIN=pychess.sbmesh.com ADMINS=sb ./scripts/install-nginx-letsencrypt.sh
# Optional: LE_EMAIL=you@example.com  PORT=18080  APP_USER=<user>  SKIP_BUILD=1
#   Fishnet AI worker: SKIP_FISHNET=1 to skip; FISHNET_CORES=1 FISHNET_THREADS=1 FISHNET_MEMORY=64 FISHNET_CPU_QUOTA=50%
set -euo pipefail

DOMAIN="${DOMAIN:-pychess.sbmesh.com}"
ADMINS="${ADMINS:-sb}"
PORT="${PORT:-18080}"  # 8080 is taken on this host
LE_EMAIL="${LE_EMAIL:-}"
APP_USER="${APP_USER:-${SUDO_USER:-$(id -un)}}"
APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE=/etc/pychess.env
UNIT=/etc/systemd/system/pychess.service
SITE=/etc/nginx/sites-available/$DOMAIN

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)." >&2; exit 1; }

as_app() { sudo -u "$APP_USER" -H bash -lc "$*"; }

echo "==> Installing packages"
apt-get update
apt-get install -y nginx certbot curl

echo "==> Prerequisites: uv, Node 24, yarn"
APP_HOME="$(getent passwd "$APP_USER" | cut -d: -f6)"
UV_BIN="$(as_app "export PATH=\"$APP_HOME/.local/bin:$APP_HOME/.cargo/bin:\$PATH\"; command -v uv" || true)"
if [ -z "$UV_BIN" ]; then
    as_app 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    UV_BIN="$APP_HOME/.local/bin/uv"
fi
[ -x "$UV_BIN" ] || { echo "uv install failed" >&2; exit 1; }

# package.json requires node 24.x and yarn 1.x
if [ "$(node -v 2>/dev/null | cut -d. -f1)" != "v24" ]; then
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
    apt-get install -y nodejs
fi
command -v yarn >/dev/null || npm install -g yarn

echo "==> MongoDB"
MONGO_PORT="${MONGO_PORT:-37017}"  # Docker host port; outside the Steam/Source 27000-27050 range
if systemctl list-unit-files | grep -q '^mongod\.service'; then
    MONGO_PORT=27017   # native mongod listens on its default port
    systemctl enable --now mongod
elif command -v docker >/dev/null; then
    # Docker fallback; MONGO_PORT is the host port (override if taken).
    if docker container inspect pychess-mongo >/dev/null 2>&1; then
        docker start pychess-mongo >/dev/null
    else
        if ss -ltn | awk '{print $4}' | grep -q ":$MONGO_PORT\$"; then
            echo "Port $MONGO_PORT is already in use; re-run with MONGO_PORT=<free port>." >&2
            exit 1
        fi
        docker run -d --name pychess-mongo --restart unless-stopped \
            -p 127.0.0.1:$MONGO_PORT:27017 -v pychess-mongo:/data/db mongo:7
    fi
else
    echo "No mongod or docker found. Install MongoDB, then re-run." >&2
    exit 1
fi

echo "==> Building app as $APP_USER"
if [ -z "${SKIP_BUILD:-}" ]; then
    # Build without proxies: yarn 1 can't use the socks5 proxy set in ~/.npmrc; empty env overrides it.
    as_app "unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy; \
        export npm_config_proxy= npm_config_https_proxy=; \
        cd '$APP_DIR' && '$UV_BIN' sync && yarn install && yarn prod && yarn md"
fi

echo "==> Environment file $ENV_FILE"
if [ ! -f "$ENV_FILE" ]; then
    FERNET_KEY="$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')"
    umask 077
    cat > "$ENV_FILE" <<EOF
URI=https://$DOMAIN
PROD=true
PORT=$PORT
MONGO_HOST=mongodb://127.0.0.1:$MONGO_PORT
FERNET_KEY=$FERNET_KEY
ADMINS=$ADMINS
EOF
    chmod 600 "$ENV_FILE"
else
    echo "    exists, leaving it alone"
fi

echo "==> systemd unit"
cat > "$UNIT" <<EOF
[Unit]
Description=Pychess variants server
After=network.target mongod.service docker.service

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$UV_BIN run server/server.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now pychess

echo "==> nginx (HTTP only, for the ACME challenge)"
mkdir -p /var/www/html
cat > "$SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sf "$SITE" /etc/nginx/sites-enabled/$DOMAIN
nginx -t
systemctl reload nginx

echo "==> Let's Encrypt certificate"
EMAIL_ARGS=(--register-unsafely-without-email)
[ -n "$LE_EMAIL" ] && EMAIL_ARGS=(-m "$LE_EMAIL")
certbot certonly --webroot -w /var/www/html -d "$DOMAIN" \
    --agree-tos --non-interactive "${EMAIL_ARGS[@]}"

echo "==> nginx (full TLS reverse proxy)"
cat > "$SITE" <<EOF
map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;   # nginx < 1.25.1 has no standalone "http2 on;"
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    client_max_body_size 5m;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF
nginx -t
systemctl reload nginx

# Reload nginx after each automatic renewal.
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

if [ -z "${SKIP_FISHNET:-}" ]; then
    echo "==> Fishnet worker (Fairy-Stockfish AI), low-resource"
    FISHNET_CORES="${FISHNET_CORES:-1}"
    FISHNET_THREADS="${FISHNET_THREADS:-1}"
    FISHNET_MEMORY="${FISHNET_MEMORY:-64}"
    FISHNET_CPU_QUOTA="${FISHNET_CPU_QUOTA:-50%}"
    FISHNET_NAME="${FISHNET_NAME:-local-worker}"
    FISHNET_ENV=/etc/fairyfishnet.env
    FISHNET_DIR="$APP_HOME/.fairyfishnet"

    as_app "'$UV_BIN' tool install --upgrade --with pip fairyfishnet"
    FISHNET_BIN="$APP_HOME/.local/bin/fairyfishnet"
    [ -x "$FISHNET_BIN" ] || { echo "fairyfishnet install failed" >&2; exit 1; }
    install -d -o "$APP_USER" -g "$APP_USER" "$FISHNET_DIR"

    # Worker key: kept in $FISHNET_ENV and registered in MongoDB (the server loads keys at startup).
    if [ ! -f "$FISHNET_ENV" ]; then
        (umask 077; echo "FISHNET_KEY=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')" > "$FISHNET_ENV")
    fi
    FISHNET_KEY="$(sed -n 's/^FISHNET_KEY=//p' "$FISHNET_ENV")"
    as_app "cd '$APP_DIR' && '$UV_BIN' run python -c \"
from pymongo import MongoClient
c = MongoClient('mongodb://127.0.0.1:$MONGO_PORT')['pychess-variants']['fishnet']
c.delete_many({'name': '$FISHNET_NAME'})
c.insert_one({'_id': '$FISHNET_KEY', 'name': '$FISHNET_NAME'})
\""

    cat > /etc/systemd/system/fairyfishnet.service <<EOF
[Unit]
Description=Fairy-Stockfish fishnet worker for pychess
After=pychess.service
Wants=pychess.service

[Service]
User=$APP_USER
WorkingDirectory=$FISHNET_DIR
EnvironmentFile=$FISHNET_ENV
# Talk to the local app directly (no Cloudflare/nginx hop).
ExecStart=$FISHNET_BIN --no-conf --key \${FISHNET_KEY} --endpoint http://127.0.0.1:$PORT/fishnet/ --cores $FISHNET_CORES --threads-per-process $FISHNET_THREADS --memory $FISHNET_MEMORY --fixed-backoff run
Restart=always
RestartSec=10
Nice=15
CPUQuota=$FISHNET_CPU_QUOTA
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    # Restart the app so it loads the new key from MongoDB, then start the worker.
    systemctl restart pychess
    systemctl enable --now fairyfishnet
fi

echo "==> Done: https://$DOMAIN  (logs: journalctl -u pychess -f)"
echo "    Register the user '$ADMINS' on the site to get admin rights."
