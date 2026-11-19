#!/usr/bin/env bash
# Debian 12/13: inspect native nginx and upgrade to official nginx 1.31.9.
# Usage: bash nginx-check-upgrade.sh [--check|--help]
set -Eeuo pipefail
export LC_ALL=C
TARGET=1.31.9
MODE="${1:-upgrade}"
case "$MODE" in
  --help|-h) echo '用法：bash nginx-check-upgrade.sh [--check]'; echo '默认检查并升级；--check 仅检查，不安装、不修改配置。'; exit 0 ;;
  --check|upgrade) ;;
  *) echo '参数错误。使用 --help 查看用法。' >&2; exit 2 ;;
esac
die() { echo "停止：$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请使用 root 或 sudo bash 执行。'
[[ -r /etc/os-release ]] || die '无法识别系统。'
. /etc/os-release
[[ ${ID:-} == debian ]] || die '此脚本只支持 Debian 12/13，不修改当前系统。'
case "${VERSION_ID:-}" in
  12) suite=bookworm ;;
  13) suite=trixie ;;
  *) die '此脚本只支持 Debian 12/13。' ;;
esac
arch="$(dpkg --print-architecture)"
[[ $arch == amd64 || $arch == arm64 ]] || die "不支持的架构：$arch"
command -v nginx >/dev/null || die '宿主机未找到 nginx；Docker 内的 nginx 需单独更新镜像。'
[[ $(dpkg-query -W -f='${Status}' nginx 2>/dev/null) == 'install ok installed' ]] || die 'nginx 不是已安装的 Debian 软件包，需单独评估。'
[[ $(readlink -f "$(command -v nginx)") == /usr/sbin/nginx ]] || die '发现自定义 nginx 路径，需单独评估。'
systemctl cat nginx >/dev/null 2>&1 || die '没有可识别的 nginx systemd 服务。'
unit_exec="$(systemctl show nginx -p ExecStart --value)"
[[ $unit_exec == *'/usr/sbin/nginx'* ]] || die 'nginx 服务使用自定义程序路径。'
[[ ! $unit_exec =~ [[:space:]]-c[[:space:]] ]] || die 'nginx 服务指定了自定义配置路径，需单独评估。'

echo "系统：$PRETTY_NAME / $arch"
nginx -v
dpkg-query -W -f='安装包：${Package} ${Version}\n' nginx
config_dump="$(nginx -T 2>&1)" || die "当前配置检查失败：$config_dump"
echo '相关配置（只显示监听、HTTP/2、HTTP/3、模块加载）：'
printf '%s\n' "$config_dump" | grep -nE '^[[:space:]]*(listen|http2|http3|load_module)[[:space:]]' || true
echo '注意：监听本机地址的服务仍可能被 Xray/Reality 或其他转发服务暴露。'
echo '此检查不等同于外部可达性测试，也不检查 Linux 内核漏洞。'
modules="$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n' 'libnginx-mod-*' 'nginx-module-*' 2>/dev/null || true)"
modules="$(printf '%s\n' "$modules" | awk '$2 == "installed" {print $1}')"
blocked=0
if [[ -n $modules ]] || printf '%s\n' "$config_dump" | grep -qE '^[[:space:]]*load_module[[:space:]]'; then
  echo "发现动态模块，自动升级将停止：${modules:-配置中存在 load_module}"
  blocked=1
fi
current="$(nginx -v 2>&1 | sed -n 's/.*nginx\///p')"
if [[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && dpkg --compare-versions "$current" ge "$TARGET"; then
  echo "当前程序版本已达到 $TARGET；不降级、不重装。"
  echo '如刚安装过新版，仍需确认服务已重启，运行中的进程使用新版程序。'
  exit 0
fi
if [[ $MODE == --check ]]; then
  echo "检查结束：当前程序低于 $TARGET；是否有发行版回补补丁需另查完整包版本公告。"
  exit 0
fi
[[ $blocked == 0 ]] || die '需要先处理动态模块兼容性。'
systemctl is-active --quiet nginx || die 'nginx 当前未运行，先处理现有服务问题。'
echo "即将切换到官方 mainline 仓库并安装 $TARGET；Nginx 会短暂重启。"

umask 077
backup="$(mktemp -d /root/nginx-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX)"
cp -a /etc/nginx "$backup/nginx"
cp -a /etc/apt "$backup/apt"
cp -a /usr/sbin/nginx "$backup/nginx.old"
dpkg-query -W > "$backup/packages.txt"
systemctl cat nginx > "$backup/nginx-service.txt"
printf '%s\n' "$config_dump" > "$backup/config-before.txt"
trap 'rc=$?; echo "升级未完成（退出码 $rc）。备份：$backup。请保留输出，不要执行 purge/autoremove；脚本不会自动回退软件包。" >&2' ERR
echo "备份：$backup"

apt-get update
apt-get install -y curl gnupg ca-certificates
curl --retry 2 --connect-timeout 15 -fsSL https://nginx.org/keys/nginx_signing.key -o "$backup/nginx_signing.key"
gpg --batch --show-keys --with-colons "$backup/nginx_signing.key" > "$backup/key-info.txt"
grep -q '^fpr:::::::::573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62:' "$backup/key-info.txt" || die '官方密钥指纹未匹配，未添加仓库。'
gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg "$backup/nginx_signing.key"
chmod 644 /usr/share/keyrings/nginx-archive-keyring.gpg
printf 'deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/mainline/debian %s nginx\n' "$suite" > /etc/apt/sources.list.d/nginx.list
printf 'Package: nginx nginx-module-*\nPin: origin nginx.org\nPin-Priority: 900\n' > /etc/apt/preferences.d/99nginx
apt-get update
apt-cache madison nginx > "$backup/available-versions.txt"
package_version="$(awk '$3 ~ /^1\.31\.9-/ && /nginx\.org/ {print $3; exit}' "$backup/available-versions.txt")"
[[ -n $package_version ]] || die "官方仓库未找到 $TARGET；备份：$backup"
apt-get -s install "nginx=$package_version" > "$backup/install-plan.txt"
cat "$backup/install-plan.txt"
unexpected="$(awk '$1 == "Remv" && $2 != "nginx-common" {print $2}' "$backup/install-plan.txt")"
[[ -z $unexpected ]] || die "升级计划需要移除其他软件包：$unexpected；未执行 nginx 安装。"
echo "安装：$package_version"
DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install "nginx=$package_version"

# Restore the original complete configuration, even if dpkg replaced an unmodified conffile.
# Move only the official default site that did not exist before this upgrade.
if [[ ! -e $backup/nginx/conf.d/default.conf && ! -L $backup/nginx/conf.d/default.conf && -e /etc/nginx/conf.d/default.conf ]]; then
  mv /etc/nginx/conf.d/default.conf "$backup/default.conf.from-official-package"
fi
cp -a "$backup/nginx/." /etc/nginx/
nginx -t
systemctl daemon-reload
systemctl restart nginx
systemctl is-active --quiet nginx
installed="$(nginx -v 2>&1)"
[[ $installed == "nginx version: nginx/$TARGET" ]] || die "程序版本不符合预期：$installed"
nginx_pid="$(systemctl show nginx -p MainPID --value)"
[[ $nginx_pid =~ ^[1-9][0-9]*$ ]] || die '未找到 nginx 主进程。'
cmp -s /usr/sbin/nginx "/proc/$nginx_pid/exe" || die '运行中的主进程与安装的程序不一致。'
trap - ERR
echo '升级成功。'
echo "$installed"
echo "服务：active；已验证运行中的主进程使用新版程序。"
echo "备份：$backup"
echo '请再测试网站及代理节点；此脚本只升级 nginx，不修复 Linux 内核漏洞。'
