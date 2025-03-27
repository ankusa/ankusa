#!/bin/bash

# Cloudflare API Credentials
CF_EMAIL="webmaster.ankush@gmail.com"
CF_API_KEY="NraSS1porJ6iFYaiHv9-5XgH1FNbcGbWttu1Vcq1"
CF_ZONE_ID="e49bd77e68f65f3b50dad5f518b012ae"
DOMAIN="home.cheapgeeky.com"
TUNNEL_NAME="home"

echo "Updating system..."
apt update && apt upgrade -y

echo "Installing required packages..."
apt install -y curl sudo nano

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
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Start Cloudflare login process
echo "Please log in to Cloudflare. Follow the link below:"
cloudflared tunnel login &

# Wait for user login (5 minutes)
sleep 300

# If login not detected, wait another 10 minutes
if [ ! -f "/root/.cloudflared/cert.pem" ]; then
    echo "Cloudflared login not detected. Waiting another 10 minutes..."
    sleep 600
fi

# If still not logged in, exit
if [ ! -f "/root/.cloudflared/cert.pem" ]; then
    echo "Cloudflare login failed. Please check and log in manually."
    exit 1
fi

echo "Login successful. Proceeding..."

# Get existing tunnel ID (if any)
EXISTING_TUNNEL_ID=$(cloudflared tunnel list | grep "$TUNNEL_NAME" | awk '{print $1}')
if [ -n "$EXISTING_TUNNEL_ID" ]; then
    echo "Deleting existing Cloudflare tunnel: $EXISTING_TUNNEL_ID"
    cloudflared tunnel delete "$EXISTING_TUNNEL_ID"
fi

# Delete DNS record via API
echo "Deleting existing DNS record for $DOMAIN..."
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

# Create new DNS record via API
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

# Setting up Cloudflared service
echo "Setting up Cloudflared as a system service..."
cat <<EOF > /etc/systemd/system/cloudflared.service
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Restart=always
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run

[Install]
WantedBy=multi-user.target
EOF

# Enable and start Cloudflared service
systemctl enable cloudflared
systemctl start cloudflared

echo "Cloudflared setup complete. Tunnel is running."
