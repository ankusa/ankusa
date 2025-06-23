#!/data/data/com.termux/files/usr/bin/bash

# 📦 Step 1: Update and install dependencies
echo "[*] Updating Termux and installing packages..."
pkg update -y && pkg upgrade -y
pkg install -y git apache2 php termux-api

# 📂 Step 2: Clone the Stalker-Portal
echo "[*] Cloning Stalker-Portal..."
git clone https://github.com/Jitendraunatti/Stalker-Portal.git ~/Stalker-Portal

# 🚚 Step 3: Move contents to Apache web root
echo "[*] Moving files to web server directory..."
WEBROOT=/data/data/com.termux/files/usr/share/apache2/default-site/htdocs
rm -rf $WEBROOT/*
cp -r ~/Stalker-Portal/* $WEBROOT/

# 🧹 Step 4: Remove default index.html if exists
[ -f $WEBROOT/index.html ] && rm $WEBROOT/index.html

# ▶️ Step 5: Start Apache server
echo "[*] Starting Apache server..."
apachectl start

# 🔁 Step 6: Setup auto-start using Termux:Boot
echo "[*] Setting up auto-start via Termux:Boot..."
mkdir -p ~/.termux/boot
BOOT_SCRIPT=~/.termux/boot/start_stalker.sh

cat << 'EOF' > $BOOT_SCRIPT
#!/data/data/com.termux/files/usr/bin/bash
apachectl start
EOF

chmod +x $BOOT_SCRIPT

# ✅ Done
echo "[✓] Installation complete!"
echo "Open your browser at http://<device-ip>:8080"
echo "Make sure Termux:Boot is installed and opened once."
