#!/bin/bash

# Update system
sudo apt update && sudo apt upgrade -y

# Install dependencies
sudo apt install curl sudo nano -y

# === Install AdGuard Home ===
echo "Installing AdGuard Home..."
curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

# === Install Cloudflared ===
echo "Installing Cloudflared..."

# Detect architecture and download appropriate binary
ARCH=$(uname -m)
if [[ $ARCH == "aarch64" ]]; then
    CLOUDFARED_BIN="cloudflared-linux-arm64"
elif [[ $ARCH == "armv7l" ]]; then
    CLOUDFARED_BIN="cloudflared-linux-arm"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/$CLOUDFARED_BIN" -o cloudflared
sudo mv cloudflared /usr/local/bin/cloudflared
sudo chmod +x /usr/local/bin/cloudflared

# Verify Cloudflared installation
cloudflared --version

# Authenticate with Cloudflare
echo "Logging into Cloudflare..."
cloudflared tunnel login

# Check if the tunnel already exists
EXISTING_TUNNEL=$(cloudflared tunnel list | grep -w "home" | awk '{print $1}')
if [[ -n "$EXISTING_TUNNEL" ]]; then
    echo "Existing tunnel 'home' found. Deleting..."
    cloudflared tunnel delete home
fi

# Create a new tunnel
echo "Creating Cloudflare tunnel..."
cloudflared tunnel create home

# Route DNS, but first delete the existing DNS route if it exists
EXISTING_DNS=$(cloudflared tunnel route dns | grep -w "home.cheapgeeky.com")
if [[ -n "$EXISTING_DNS" ]]; then
    echo "Existing DNS route for home.cheapgeeky.com found. Deleting..."
    cloudflared tunnel route dns delete home.cheapgeeky.com
fi

echo "Routing Cloudflare tunnel to home.cheapgeeky.com..."
cloudflared tunnel route dns home home.cheapgeeky.com

# Get the new Tunnel ID
TUNNEL_ID=$(cloudflared tunnel list | grep home | awk '{print $1}')

# Create Cloudflared config file
echo "Configuring Cloudflared..."
sudo mkdir -p /etc/cloudflared
sudo tee /etc/cloudflared/config.yml > /dev/null <<EOL
tunnel: $TUNNEL_ID
credentials-file: /root/.cloudflared/$TUNNEL_ID.json

ingress:
  - hostname: home.cheapgeeky.com
    service: http://198.168.29.3:80
  - service: http_status:404
EOL

# Create Cloudflared systemd service
echo "Setting up Cloudflared as a service..."
sudo tee /etc/systemd/system/cloudflared.service > /dev/null <<EOL
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
Restart=always
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run

[Install]
WantedBy=multi-user.target
EOL

# Enable and start Cloudflared service
sudo systemctl daemon-reload
sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

# Restart DietPi services
dietpi-services restart

# Check service status
echo "Checking Cloudflared status..."
sudo systemctl status cloudflared --no-pager

# Display success message
echo "Installation complete! AdGuard Home and Cloudflare Tunnel are now running."
