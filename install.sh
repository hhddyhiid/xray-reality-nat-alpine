#!/bin/ash
set -eu

LOCAL_PORT=""
PUBLIC_PORT=""
NAME="Reality-TCP-NAT"
SNI="www.microsoft.com"
DEST="www.microsoft.com:443"
XRAY="/usr/local/bin/xray"

usage() {
  cat <<EOF
Usage:
  ash install.sh
  ash install.sh --public 49330
  ash install.sh --local 8443 --public 49330 --name JP-Reality-TCP
  ash install.sh --name JP-Reality-TCP
  ash install.sh --sni www.ubuntu.com

Options:
  --local    Local listen port. (CRITICAL for NAT VPS: Must be an allowed port)
  --public   Public forwarded port. Optional
  --name     Node name. Default: Reality-TCP-NAT
  --sni      REALITY SNI. Default: www.microsoft.com (Tip: Choose an SNI matching your VPS location)
  --dest     REALITY dest. Default: <SNI>:443
  -h|--help  Show help

Examples:
  # Random local port, suitable for dedicated IP VPS
  ash install.sh

  # Random local port, known public NAT port
  ash install.sh --public 49330

  # Fixed local port and known public NAT port (Recommended for NAT VPS)
  ash install.sh --local 8443 --public 49330 --name JP-Reality-TCP --sni www.ubuntu.com
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local)
      LOCAL_PORT="$2"
      shift 2
      ;;
    --public)
      PUBLIC_PORT="$2"
      shift 2
      ;;
    --name)
      NAME="$2"
      shift 2
      ;;
    --sni)
      SNI="$2"
      DEST="${SNI}:443"
      shift 2
      ;;
    --dest)
      DEST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

check_port() {
  port="$1"

  case "$port" in
    ''|*[!0-9]*)
      echo "Invalid port: $port"
      exit 1
      ;;
  esac

  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Port out of range: $port"
    exit 1
  fi
}

random_port() {
  while true; do
    port="$(od -An -N2 -tu2 /dev/urandom | awk '{print 20000 + ($1 % 40000)}')"

    if ! netstat -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"; then
      echo "$port"
      return
    fi
  done
}

if [ "$(id -u)" != "0" ]; then
  echo "Please run as root."
  exit 1
fi

if [ ! -f /etc/alpine-release ]; then
  echo "Warning: This script is designed for Alpine Linux with OpenRC."
fi

echo "[1/6] Installing dependencies..."
# Added jq for JSON validation, iptables for basic firewall handling
apk update
apk add --no-cache curl unzip openssl ca-certificates net-tools jq iptables ip6tables

if [ -z "$LOCAL_PORT" ]; then
  LOCAL_PORT="$(random_port)"
  echo "Random local listen port generated: ${LOCAL_PORT}"
else
  check_port "$LOCAL_PORT"
  echo "Using specified local listen port: ${LOCAL_PORT}"
fi

if [ -n "$PUBLIC_PORT" ]; then
  check_port "$PUBLIC_PORT"
  LINK_PORT="$PUBLIC_PORT"
else
  LINK_PORT="$LOCAL_PORT"
fi

echo "[2/6] Installing or updating Xray..."
cd /tmp
# Added connection timeout and error handling for the external script download
if ! curl -L --connect-timeout 10 -o install-release.sh https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh; then
  echo "Error: Failed to download Xray installation script. Please check your network."
  exit 1
fi
ash install-release.sh

echo "[3/6] Generating UUID and REALITY keys..."

UUID="$($XRAY uuid)"
KEYS="$($XRAY x25519 2>&1)"

PRIVATE_KEY="$(echo "$KEYS" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}' | tr -d '\r\n ')"
PUBLIC_KEY="$(echo "$KEYS" | awk -F': *' '/PublicKey|Public key/ {print $2; exit}' | tr -d '\r\n ')"

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "Failed to parse REALITY keys."
  echo "Raw output:"
  echo "$KEYS"
  exit 1
fi

SHORT_ID="$(openssl rand -hex 8)"

echo "[4/6] Writing and validating Xray config..."

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<JSON
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-reality-tcp",
      "listen": "0.0.0.0",
      "port": ${LOCAL_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
JSON

# Validate JSON syntax using jq
if ! jq . /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  echo "Error: Failed to generate a valid JSON configuration."
  exit 1
fi

echo "[5/6] Attempting to configure firewall for port ${LOCAL_PORT}..."
if command -v iptables >/dev/null 2>&1; then
  iptables -I INPUT -p tcp --dport "${LOCAL_PORT}" -j ACCEPT 2>/dev/null || true
fi
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -I INPUT -p tcp --dport "${LOCAL_PORT}" -j ACCEPT 2>/dev/null || true
fi

echo "[6/6] Testing and starting Xray..."

$XRAY run -config /usr/local/etc/xray/config.json -test

rc-update add xray default >/dev/null 2>&1 || true
rc-service xray restart || rc-service xray start

IP4="$(curl -4 -s --max-time 5 https://api.ipify.org || true)"
IP6="$(curl -6 -s --max-time 5 https://api64.ipify.org || true)"

ADDR="${IP4:-$IP6}"
if [ -z "$ADDR" ]; then
  ADDR="YOUR_PUBLIC_IP"
fi

URI_ADDR="$ADDR"
echo "$ADDR" | grep -q ":" && URI_ADDR="[$ADDR]"

NAME_SAFE="$(echo "$NAME" | sed 's/[[:space:]]/-/g')"

IMPORT_LINK="vless://${UUID}@${URI_ADDR}:${LINK_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${NAME_SAFE}"

echo
echo "================ Installation completed ================"
echo "Protocol: VLESS"
echo "Transport: TCP"
echo "Security: REALITY"
echo "Flow: xtls-rprx-vision"
echo
echo "Local listen port: ${LOCAL_PORT}"
echo "Public connect port: ${LINK_PORT}"
echo
echo "UUID: ${UUID}"
echo "PublicKey: ${PUBLIC_KEY}"
echo "ShortID: ${SHORT_ID}"
echo "SNI: ${SNI}"
echo
echo "Import link:"
echo
echo "${IMPORT_LINK}"
echo
echo "==================== Important Notes ===================="
echo
echo "1. FIREWALL:"
echo "   The script attempted to open local port ${LOCAL_PORT} using iptables."
echo "   If your VPS provider has an external web firewall (e.g., AWS, Oracle, Azure),"
echo "   you MUST manually allow TCP port ${LOCAL_PORT} in their web console."
echo
echo "2. NAT VPS USERS:"
echo "   If this is a NAT VPS, the local port (${LOCAL_PORT}) MUST be one of the ports"
echo "   assigned to you by your provider. If you used the random port generation,"
echo "   it likely WILL NOT WORK. Reinstall using: --local <assigned_port>"
echo
echo "3. SECURITY (SNI) TIP:"
echo "   You are currently using '${SNI}' as the SNI."
echo "   For better anti-blocking, it is recommended to use an SNI that matches"
echo "   your VPS IP's geographic location (e.g., local corporate or university sites)."
echo
echo "Check status:"
echo "  rc-service xray status"
echo "  netstat -lntp | grep ${LOCAL_PORT}"
echo "========================================================="
