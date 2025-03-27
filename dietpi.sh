#!/bin/bash

# Load Cloudflare API credentials
if [ -f /root/cloudflare.env ]; then
    export $(grep -v '^#' /root/cloudflare.env | xargs)
else
    echo "Error: /root/cloudflare.env file not found!"
    exit 1
fi

# Cloudflare API Credentials (Move these to environment variables for security)
CF_EMAIL="${CF_EMAIL}"
CF_API_KEY="${CF_API_KEY}"
CF_ZONE_ID="${CF_ZONE_ID}"
DOMAIN="home.cheapgeeky.com"
TUNNEL_NAME="home"

echo "Updating system..."
apt update && apt upgrade -y

echo "Installing required packages..."
apt install -y curl sudo nano jq

# Detect system architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    CLOUD_FILE="cloudflared-linux-amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
    CLOUD_FILE="cloudflared-linux-arm64"
elif [[ "$ARCH" == "armv7l" ]]; then
    CLOUD_FILE="cloudflared-linux-arm"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Uninstall AdGuard Home if it exists
if [ -d "/opt/AdGuardHome" ]; then
    echo "Removing existing AdGuard Home installation..."
    sudo /opt/AdGuardHome/AdGuardHome -s stop
    sudo /opt/AdGuardHome/AdGuardHome -s uninstall
    rm -rf /opt/AdGuardHome
fi

# Install AdGuard Home
echo "Installing AdGuard Home..."
curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | bash
sleep 10
echo "AdGuard Home installation complete."

# Install Cloudflared
echo "Installing Cloudflared..."
mkdir -p /usr/local/bin
curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$CLOUD_FILE" -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Start Cloudflare login process
echo "Please log in to Cloudflare. Follow the link below:"
cloudflared tunnel login &

# Wait for Cloudflare login (check every 10 seconds, max 5 minutes)
echo "Waiting for Cloudflared login..."
for i in {1..30}; do
    if [ -f "/root/.cloudflared/cert.pem" ]; then
        echo "Cloudflared login detected."
        break
    fi
    sleep 10
done

if [ ! -f "/root/.cloudflared/cert.pem" ]; then
    echo "Cloudflare login failed. Please check and log in manually."
    exit 1
fi

echo "Login successful. Proceeding..."

# Get existing tunnel ID
EXISTING_TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
if [ -n "$EXISTING_TUNNEL_ID" ]; then
    echo "Deleting existing Cloudflare tunnel: $EXISTING_TUNNEL_ID"
    cloudflared tunnel delete "$EXISTING_TUNNEL_ID"
fi

# Delete existing DNS record
EXISTING_DNS_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_API_KEY" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$EXISTING_DNS_ID" != "null" ]; then
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$EXISTING_DNS_ID" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json"
    echo "Deleted existing DNS record."
fi

# Create new Cloudflare tunnel
echo "Creating new Cloudflare tunnel..."
cloudflared tunnel create "$TUNNEL_NAME"

# Get new tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
if [ -z "$TUNNEL_ID" ]; then
    echo "Failed to create Cloudflare tunnel."
    exit 1
fi

# Configure Cloudflared
echo "Configuring Cloudflared..."
mkdir -p /etc/cloudflared
cat <<EOF > /etc/cloudflared/config.yml
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/cert.pem
ingress:
  - hostname: $DOMAIN
    service: http://localhost:3000
  - service: http_status:404
EOF

# Create new DNS record
echo "Creating new DNS record for $DOMAIN..."
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
echo "New DNS record created."

# Setting up Cloudflared as a system service
echo "Setting up Cloudflared as a system service..."
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

echo "Cloudflared setup complete. Tunnel is running."
