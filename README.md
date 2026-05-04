# xray-reality-nat-alpine

Alpine NAT VPS 一键安装 VLESS + TCP + REALITY + Vision。

适合于有 TCP 端口转发、不能转发 UDP 的 NAT 小鸡。（其他也可尝试）

## 一键使用指令

```bash
apk add --no-cache curl && curl -fsSL -o install.sh https://raw.githubusercontent.com/hhddyhiid/xray-reality-nat-alpine/main/install.sh && ash install.sh

```
## 使用方法（分步与自定义）
如果你的 NAT 小鸡需要指定内网端口，可以下载后带参数运行：
```bash

apk add --no-cache curl
curl -fsSL -o install.sh https://raw.githubusercontent.com/hhddyhiid/xray-reality-nat-alpine/main/install.sh

# 默认安装（随机端口）
ash install.sh

# 自定义参数安装（示例：指定本地监听 8443，公网映射 49330）
ash install.sh --local 8443 --public 49330 --name JP-Node --sni www.ubuntu.com
```
*提示：可选参数有 --local (本地端口), --public (公网端口), --name (节点名), --sni (伪装域名)*
## 管理与查看
**查看状态**
```bash
rc-service xray status

```
**重启**
```bash
rc-service xray restart

```
**查看监听端口**
```bash
netstat -lntp

```
