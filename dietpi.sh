#!/bin/bash

echo "Updating system..."
apt update && apt upgrade -y

echo "Installing required packages..."
apt install -y curl sudo nano jq

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

# Wait for AdGuard Home setup completion
sleep 10
echo "AdGuard Home installation complete."

# Install Cloudflared
echo "Installing Cloudflared..."
mkdir -p /usr/local/bin
curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64 -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

# Wait for Cloudflare login (5 minutes)
echo "Waiting for 5 minutes to log in to Cloudflare..."
sleep 300  # 5-minute wait

# Check if login was successful
if [ ! -f "/root/.cloudflared/cert.pem" ]; then
    echo "Cloudflared login not detected. Waiting for another 10 minutes..."
    sleep 600  # 10-minute wait
fi

# Attempt login again
if [ ! -f "/root/.cloudflared/cert.pem" ]; then
    echo "Cloudflared login failed. Please check your credentials and manually log in."
    exit 1
fi

echo "Logging into Cloudflare..."
cloudflared tunnel login

# Cloudflare API Credentials
CF_EMAIL="webmaster.ankush@gmail.com"
CF_API_KEY="NraSS1porJ6iFYaiHv9-5XgH1FNbcGbWttu1Vcq1"
CF_ZONE_ID="e49bd77e68f65f3b50dad5f518b012ae"
DOMAIN="home.cheapgeeky.com"

# Delete existing Cloudflare tunnel
echo "Checking for existing tunnels..."
EXISTING_TUNNEL_ID=$(cloudflared tunnel list | grep "home" | awk '{print $1}')
if [ -n "$EXISTING_TUNNEL_ID" ]; then
    echo "Deleting existing tunnel: $EXISTING_TUNNEL_ID"
    cloudflared tunnel delete "$EXISTING_TUNNEL_ID"
fi

# Delete existing DNS record (via Cloudflare API)
echo "Checking for existing DNS record..."
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DOMAIN" \
    -H "X-Auth-Email: $CF_EMAIL" \
    -H "X-Auth-Key: $CF_API_KEY" \
    -H "Content-Type: application/json" | jq -r '.result[0].id')

if [ "$RECORD_ID" != "null" ]; then
    echo "Deleting DNS record: $RECORD_ID"
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$RECORD_ID" \
        -H "X-Auth-Email: $CF_EMAIL" \
        -H "X-Auth-Key: $CF_API_KEY" \
        -H "Content-Type: application/json"
fi

# Creating Cloudflare tunnel
echo "Creating new Cloudflare tunnel..."
cloudflared tunnel create home

# Get new tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep "home" | awk '{print $1}')
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
    service: http://192.168.29.3:80
  - service: http_status:404
EOF

# Routing the domain
echo "Routing Cloudflare tunnel to $DOMAIN..."
cloudflared tunnel route dns "$TUNNEL_ID" "$DOMAIN"

# Setting up Cloudflared service
echo "Setting up Cloudflared as a service..."
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

echo "✅ Cloudflared setup complete."
echo "✅ Installation finished! AdGuard Home and Cloudflare Tunnel are now running."
