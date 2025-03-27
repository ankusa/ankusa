#!/bin/bash

set -e  # Exit on error
set -o pipefail  # Catch errors in pipelines

LOG_FILE="/var/log/cloudflared_setup.log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Redirect output to log file

echo "🚀 Starting Cloudflare Tunnel & AdGuard Home Setup..."

# Load Cloudflare API credentials
CREDENTIALS_FILE="/root/cloudflare.env"
if [ -f "$CREDENTIALS_FILE" ]; then
    export $(grep -v '^#' "$CREDENTIALS_FILE" | xargs)
else
    echo "❌ Error: $CREDENTIALS_FILE not found!"
    exit 1
fi

# Cloudflare API Credentials
DOMAIN="home.cheapgeeky.com"
TUNNEL_NAME="home"
CERT_PATH="/root/.cloudflared/cert.pem"

# Ensure necessary tools are installed
echo "🔄 Updating system and installing required packages..."
apt update && apt upgrade -y
apt install -y curl sudo nano jq unzip

# Determine system architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) CLOUD_FILE="cloudflared-linux-amd64" ;;
    aarch64) CLOUD_FILE="cloudflared-linux-arm64" ;;
    armv7l) CLOUD_FILE="cloudflared-linux-arm" ;;
    *) echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Install Cloudflared if missing
if ! command -v cloudflared &> /dev/null; then
    echo "📥 Installing Cloudflared..."
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$CLOUD_FILE" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    echo "✅ Cloudflared installed."
fi

# Remove existing AdGuard Home
if [ -d "/opt/AdGuardHome" ]; then
    echo "🗑️ Removing existing AdGuard Home..."
    /opt/AdGuardHome/AdGuardHome -s stop
    /opt/AdGuardHome/AdGuardHome -s uninstall
    rm -rf /opt/AdGuardHome
fi

# Install AdGuard Home
echo "📥 Installing AdGuard Home..."
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | bash
echo "✅ AdGuard Home installed."

# Fetch Cloudflare Tunnel certificate if not present
if [ ! -f "$CERT_PATH" ]; then
    echo "🔑 Fetching Cloudflare Tunnel certificate..."
    cloudflared tunnel login
    if [ ! -f "$CERT_PATH" ]; then
        echo "❌ Failed to fetch Cloudflare Tunnel certificate. Check API credentials or retry login."
        exit 1
    fi
    echo "✅ Cloudflare Tunnel certificate fetched successfully."
else
    echo "✅ Cloudflare Tunnel certificate already exists. Skipping login."
fi

# Check if the tunnel exists, delete if needed
EXISTING_TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
if [ -n "$EXISTING_TUNNEL_ID" ]; then
    echo "🗑️ Deleting existing Cloudflare tunnel: $EXISTING_TUNNEL_ID"
    cloudflared tunnel delete "$EXISTING_TUNNEL_ID"
fi

# Create new Cloudflare tunnel
echo "🔧 Creating new Cloudflare tunnel..."
cloudflared tunnel create "$TUNNEL_NAME"

# Get new tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
if [ -z "$TUNNEL_ID" ]; then
    echo "❌ Failed to create Cloudflare tunnel."
    exit 1
fi

# Configure Cloudflared
echo "⚙ Configuring Cloudflared..."
mkdir -p /etc/cloudflared
cat <<EOF > /etc/cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: $CERT_PATH
ingress:
  - hostname: $DOMAIN
    service: http://localhost:3000
  - service: http_status:404
EOF

# Remove existing DNS record
EXISTING_DNS_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_API_KEY" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$EXISTING_DNS_ID" != "null" ]; then
    echo "🗑️ Deleting existing DNS record..."
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$EXISTING_DNS_ID" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json"
fi

# Create new DNS record
echo "🌐 Creating new DNS record for $DOMAIN..."
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_API_KEY" \
    -H "Content-Type: application/json" \
    --data '{
        "type": "CNAME",
        "name": "'"$DOMAIN"'",
        "content": "'"$TUNNEL_ID"'.cfargotunnel.com",
        "ttl": 1,
        "proxied": true
    }'
echo "✅ DNS record created."

# Setting up Cloudflared as a system service
echo "📌 Setting up Cloudflared as a system service..."
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Restart=always
RestartSec=10
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Cloudflared service
systemctl enable cloudflared
systemctl start cloudflared

echo "✅ Cloudflare Tunnel & AdGuard Home setup completed successfully!"
