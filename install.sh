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
  --local    Local listen port. Default: random port
  --public   Public forwarded port. Optional
  --name     Node name. Default: Reality-TCP-NAT
  --sni      REALITY SNI. Default: www.microsoft.com
  --dest     REALITY dest. Default: <SNI>:443
  -h|--help  Show help

Examples:
  # Random local port, suitable for dedicated public IP VPS
  ash install.sh

  # Random local port, known public NAT port
  ash install.sh --public 49330

  # Fixed local port and known public NAT port, recommended for fixed NAT mapping
  ash install.sh --local 8443 --public 49330 --name JP-Reality-TCP

  # Custom SNI
  ash install.sh --local 8443 --public 49330 --sni www.ubuntu.com
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
      echo
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

echo "[1/5] Installing dependencies..."
apk update
apk add --no-cache curl unzip openssl ca-certificates net-tools

if [ -z "$LOCAL_PORT" ]; then
  LOCAL_PORT="$(random_port)"
  echo "Random local listen port: ${LOCAL_PORT}"
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

echo "[2/5] Installing or updating Xray..."
cd /tmp

if ! curl -fsSL --connect-timeout 10 -o install-release.sh https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh; then
  echo "Error: Failed to download Xray installation script. Please check your network."
  exit 1
fi

ash install-release.sh

if [ ! -x "$XRAY" ]; then
  echo "Error: Xray binary not found at ${XRAY}."
  exit 1
fi

echo "[3/5] Generating UUID and REALITY keys..."

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

echo "[4/5] Writing Xray config..."

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

echo "[5/5] Testing and starting Xray..."

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
echo "Public connect port in link: ${LINK_PORT}"
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
echo "================ 安装完成 ================"
echo "协议 (Protocol): VLESS"
echo "传输 (Transport): TCP"
echo "安全 (Security): REALITY"
echo "流控 (Flow): xtls-rprx-vision"
echo
echo "本地监听端口: ${LOCAL_PORT}"
echo "链接中的公网端口: ${LINK_PORT}"
echo
echo "UUID: ${UUID}"
echo "PublicKey: ${PUBLIC_KEY}"
echo "ShortID: ${SHORT_ID}"
echo "SNI: ${SNI}"
echo
echo "导入链接 (Import link):"
echo
echo "${IMPORT_LINK}"
echo
echo "==================== 重要提示 ===================="
echo
echo "1. 独立公网 IP 的 VPS（独立小鸡）："
echo "   如果你的机器有独立公网 IP，请直接复制上面的链接导入客户端即可。"
echo "   不需要设置任何 NAT 端口转发。"
echo
echo "2. NAT VPS（NAT 小鸡）："
echo "   如果这是 NAT 小鸡，请去你的商家控制面板创建一个 TCP 端口转发规则："
echo
echo "   公网 TCP 端口 (你的外部端口) -> 内网 TCP 端口 ${LOCAL_PORT}"
echo
echo "   导入节点后，请务必将客户端中的端口修改为你映射出的【公网 TCP 端口】。"
echo
echo "   举个例子："
echo "   面板映射：公网 TCP 49330 -> 内网 TCP ${LOCAL_PORT}"
echo "   那么你的客户端节点端口就填 49330。"
echo
echo "   如果你下次安装前就已经知道公网端口了，可以这样一键安装："
echo "   ash install.sh --public 你的公网端口"
echo
echo "   如果你的商家限制了只能用指定的内网端口，请这样安装："
echo "   ash install.sh --local 商家指定的内网端口 --public 你的公网端口"
echo
echo "3. 防火墙说明："
echo "   本脚本不会修改系统防火墙规则。"
echo "   如果你的商家有外部安全组（控制台网页防火墙），请放行 TCP 端口 ${LOCAL_PORT}。"
echo "   对于大部分 NAT 小鸡，通常只需要在商家的面板里设置好端口映射即可。"
echo
echo "常用命令："
echo "  查看状态: rc-service xray status"
echo "  查看端口: netstat -lntp | grep ${LOCAL_PORT}"
echo "=================================================="
