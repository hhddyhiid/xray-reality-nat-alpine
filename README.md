# xray-reality-nat-alpine
Alpine NAT VPS one-click VLESS TCP REALITY installer Public
## 一键使用指令
apk add --no-cache curl && curl -L -o install.sh https://raw.githubusercontent.com/hhddyhiid/xray-reality-nat-alpine/main/install.sh && ash install.sh
# xray-reality-nat-alpine

Alpine NAT VPS 一键安装 VLESS + TCP + REALITY + Vision。

适合只有 TCP 端口转发、不能转发 UDP 的 NAT 小鸡。

## 使用方法

```sh
apk add --no-cache curl
curl -L -o install.sh https://raw.githubusercontent.com/你的用户名/xray-reality-nat-alpine/main/install.sh
ash install.sh
查看状态
rc-service xray status
重启
rc-service xray restart
查看监听端口
netstat -lntp
