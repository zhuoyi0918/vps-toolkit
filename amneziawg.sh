#!/usr/bin/env bash
# AmneziaWG 中文管理入口。MIT；安装引擎版权见 amneziawg/README.md。
set -Eeuo pipefail
umask 077

VERSION=1.0.3
HOME_DIR=/opt/zhuoyi-amneziawg
CLIENT_DIR=/root/awg
SERVER_CONF=/etc/amnezia/amneziawg/awg0.conf
UPSTREAM_COMMIT=a53b55ccf37c23b653a7fd21f69843bcb1323ed6
INSTALLER_SHA=6dba0136d357a1a695294eadb05ea07f49c5462b2575d2a4e4be7d325d8fa768

error() { printf '错误：%s\n' "$*" >&2; return 1; }
valid_name() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; }
require_root() { [[ "$EUID" -eq 0 ]] || error '请使用 root 或 sudo 运行。'; }
require_service() { [[ -s "$SERVER_CONF" && -s "$CLIENT_DIR/manage_amneziawg.sh" ]] || error '尚未完成安装，请先选择 1。'; }
confirm() { local reply; read -r -p "$1 [$2]：" reply || return 1; [[ "$reply" == "$2" ]]; }

dependencies() {
    local cmd need=0
    for cmd in curl python3 qrencode; do command -v "$cmd" >/dev/null || need=1; done
    if (( need )); then
        apt-get update || return
        apt-get install -y curl ca-certificates python3 qrencode || return
    fi
}

installer() {
    local dest="$HOME_DIR/upstream-install.sh" tmp
    mkdir -p "$HOME_DIR" || return
    if [[ -f "$dest" ]] && printf '%s  %s\n' "$INSTALLER_SHA" "$dest" | sha256sum --check --status; then
        printf '%s\n' "$dest"; return
    fi
    tmp=$(mktemp "$HOME_DIR/.installer.XXXXXX") || return
    if ! curl -fL --retry 3 --connect-timeout 15 --max-time 180 \
        "https://raw.githubusercontent.com/bivlked/amneziawg-installer/$UPSTREAM_COMMIT/install_amneziawg_en.sh" -o "$tmp"; then
        rm -f -- "$tmp"; error '下载安装引擎失败。'; return 1
    fi
    if ! printf '%s  %s\n' "$INSTALLER_SHA" "$tmp" | sha256sum --check --status; then
        rm -f -- "$tmp"; error '安装引擎 SHA256 校验失败，未执行。'; return 1
    fi
    chmod 700 "$tmp" && mv -f -- "$tmp" "$dest" || return
    printf '%s\n' "$dest"
}

setup() {
    if [[ -s "$SERVER_CONF" && ! -e "$CLIENT_DIR/setup_state" ]]; then
        require_service || return
        echo '已发现现有 AmneziaWG 配置，不重复安装。可选 2 查看状态、5 导出已有客户端。'
        return
    fi
    dependencies || return
    local script port rc=0
    script=$(installer) || return
    if [[ -s "$HOME_DIR/port" ]]; then
        read -r port < "$HOME_DIR/port"
    else
        read -r -p 'VPN UDP 端口 [51820]：' port || return
        port=${port:-51820}
        if ! [[ "$port" =~ ^[0-9]{1,5}$ ]]; then
            error '端口必须为 1–65535。'; return 1
        fi
        if (( 10#$port < 1 || 10#$port > 65535 )); then
            error '端口必须为 1–65535。'; return 1
        fi
        port=$((10#$port))
        if ss -H -lun | awk '{print $5}' | grep -Eq ":${port}$"; then
            error '该 UDP 端口已被占用，请换一个。'; return 1
        fi
        printf '%s\n' "$port" > "$HOME_DIR/port"
    fi
    echo '安装 AWG 2.0；会安装依赖、更新系统软件包和建立 VPN 转发/NAT。'
    echo '保留现有防火墙及 IPv6。不会自动重启；需要重启时会提示。'
    echo "请在商家安全组和系统防火墙中放行 UDP $port。"
    # 保留上游对辅助脚本的 SHA256 校验，不允许环境变量改成测试分支。
    env -u AWG_BRANCH bash "$script" --protocol=2.0 --no-tweaks --allow-ipv6 \
        --no-reboot --route-all "--port=$port" || rc=$?
    if (( rc == 75 )); then
        echo '安装已保存进度，需要重启。执行 reboot，重连后运行 awg-menu 并选择 1 继续。'
        return 0
    elif (( rc != 0 )); then
        error "安装未完成（退出码 $rc），请保留末尾错误信息。"; return "$rc"
    fi
    [[ -s "$SERVER_CONF" ]] || { error '安装器未生成服务器配置，请检查安装输出。'; return 1; }
    echo '安装步骤完成。选择 2 检查服务，再选择 5 导出客户端二维码。'
}

# 读取原生配置，生成保留所有受支持 AWG 2.0 字段的节点 URI及原生配置。
# URI 在真实小火箭上的解析兼容性需要实测；不把丢字段的导入当作成功。
export_profile() {
    python3 - "$1" "$2" "$3" <<'AWG_PYTHON'
import base64
import ipaddress
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote, urlencode, urlsplit

def fail(message):
    raise ValueError(message)

def convert(source, directory, name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,31}", name):
        fail("客户端名称无效")
    sections = {}
    section = None
    allowed = {
        "interface": {"privatekey", "address", "dns", "mtu", "jc", "jmin", "jmax",
                      "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
                      "i1", "i2", "i3", "i4", "i5"},
        "peer": {"publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"},
    }
    text = Path(source).read_text(encoding="utf-8-sig")
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].lower()
            if section not in allowed or section in sections:
                fail("仅支持单 Interface、单 Peer 客户端配置")
            sections[section] = {}
            continue
        if section is None or "=" not in line:
            fail("配置格式错误")
        key, value = (s.strip() for s in line.split("=", 1))
        key = key.lower()
        if key not in allowed[section]:
            fail("存在未支持字段，停止导出以免丢失参数：" + key)
        if not value:
            fail("存在空字段：" + key)
        if key in sections[section]:
            if key not in {"address", "dns", "allowedips"}:
                fail("重复字段：" + key)
            value = sections[section][key] + "," + value
        sections[section][key] = value
    interface, peer = sections.get("interface", {}), sections.get("peer", {})
    for group, keys in ((interface, ("privatekey", "address")), (peer, ("publickey", "endpoint", "allowedips"))):
        if any(k not in group for k in keys):
            fail("缺少必要字段")
    for key in (interface["privatekey"], peer["publickey"], peer.get("presharedkey")):
        if key is not None:
            try:
                if len(base64.b64decode(key, validate=True)) != 32:
                    fail("密钥长度无效")
            except (ValueError, base64.binascii.Error):
                fail("密钥格式无效")
    for value in interface["address"].split(","):
        ipaddress.ip_interface(value.strip())
    for value in peer["allowedips"].split(","):
        ipaddress.ip_network(value.strip(), strict=False)
    endpoint = peer["endpoint"]
    target = urlsplit("//" + endpoint)
    if (not target.hostname or not target.port or target.username or target.password
            or target.path or target.query or target.fragment or re.search(r"\s", endpoint)):
        fail("Endpoint 无效")
    # Shadowrocket 2.2.93 的实际分享格式：密钥在查询参数中，AWG 设置
    # 放入 obfsParam JSON；顶层 jc/s1 等字段不会自动开启混淆。
    query = {"publicKey": peer["publickey"], "privateKey": interface["privatekey"],
             "ip": interface["address"], "allowedips": peer["allowedips"], "udp": "1"}
    for key in ("dns", "mtu"):
        if key in interface:
            query[key] = ",".join(part.strip() for part in interface[key].split(","))
    obfs_keys = ("jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
                 "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5")
    obfs = {key: interface[key] for key in obfs_keys if key in interface}
    if obfs:
        obfs.update(random_trailers="false", disable_cookies="false")
        query["obfs"] = "amneziawg"
        query["obfsParam"] = json.dumps(obfs, separators=(",", ":"))
    if "presharedkey" in peer:
        # 保留原通用字段，并提供两种 camelCase 拼写；值始终来自原配置。
        # PSK 的客户端字段识别仍需设备核对，绝不自动更换服务器密钥。
        query["presharedkey"] = peer["presharedkey"]
        query["presharedKey"] = peer["presharedkey"]
        query["preSharedKey"] = peer["presharedkey"]
    if "persistentkeepalive" in peer:
        query["keepalive"] = peer["persistentkeepalive"]
    uri = "wg://" + endpoint + "?" + urlencode(query, quote_via=quote) + "#" + quote(name, safe="")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    if directory.is_symlink():
        fail("导出目录不能是符号链接")
    os.chmod(directory, 0o700)
    # 先验证整个配置，再用临时文件原子写入，避免留下半截密钥文件。
    for suffix, content in ((".conf", text), (".uri", uri)):
        fd, tmp = tempfile.mkstemp(prefix=".export-", dir=directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                stream.write(content)
            os.replace(tmp, directory / (name + suffix))
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)

try:
    convert(*sys.argv[1:])
except (ValueError, OSError) as error:
    print("导出失败：" + str(error), file=sys.stderr)
    sys.exit(1)
AWG_PYTHON
}

export_client() {
    require_service || return
    dependencies || return
    local name=${1:-} dest
    if [[ -z "$name" ]]; then
        select_client || return
        name=$SELECTED_CLIENT
        [[ -n "$name" ]] || return 0
    fi
    valid_name "$name" || { error '名称限 1–32 位字母、数字、下划线和连字符。'; return 1; }
    [[ -s "$CLIENT_DIR/$name.conf" && ! -L "$CLIENT_DIR/$name.conf" ]] || { error '找不到此客户端配置。'; return 1; }
    grep -qxF "#_Name = $name" "$SERVER_CONF" || { error '客户端未在服务器登记，拒绝导出。'; return 1; }
    dest="$CLIENT_DIR/exports"
    export_profile "$CLIENT_DIR/$name.conf" "$dest" "$name" || return
    # 不给二维码命令传密钥参数；通过标准输入读取本地文件。
    qrencode -l L -s 6 -o "$dest/$name.node.png" < "$dest/$name.uri" || return
    qrencode -l L -s 6 -o "$dest/$name.native.png" < "$dest/$name.conf" || return
    chmod 600 "$dest/$name.node.png" "$dest/$name.native.png"
    echo '节点链接二维码：在小火箭首页左上角扫码添加。'
    echo '兼容性待设备实测；导入后须核对 PSK、S1–S4、H1–H4、I1–I5 等参数。'
    echo '新版按小火箭分享格式导出；请删除旧导入节点后重新导入，检查混淆为 AmneziaWG。'
    qrencode -t ANSIUTF8 < "$dest/$name.uri" || return
    printf '\n节点链接（复制完整一行，到小火箭首页粘贴）：\n'
    cat -- "$dest/$name.uri" || return
    printf '\n'
    printf '\n已保存：\n%s\n%s\n%s\n%s\n' "$dest/$name.node.png" "$dest/$name.native.png" "$dest/$name.conf" "$dest/$name.uri"
    echo 'node.png 为节点链接；native.png 为原生配置二维码（供 AmneziaWG）。'
    echo '二维码若太密，请用 SFTP 下载 PNG 后扫描。全部文件含凭据，请勿公开。'
}

list_files() {
    local file
    for file in "$CLIENT_DIR"/*.conf; do
        [[ -f "$file" ]] || continue
        basename "$file" .conf
    done
}

select_client() {
    SELECTED_CLIENT=''
    local -a clients=()
    local index choice
    mapfile -t clients < <(list_files)
    if (( ${#clients[@]} == 0 )); then
        echo '暂无客户端，请先选择 4 新增客户端。'
        return 0
    fi
    echo '现有客户端：'
    for index in "${!clients[@]}"; do
        printf '%s. %s\n' "$((index + 1))" "${clients[index]}"
    done
    echo '0. 返回'
    while read -r -p '请选择客户端编号（也可输入名称）：' choice; do
        [[ "$choice" == 0 ]] && return 0
        if [[ "$choice" =~ ^[0-9]{1,6}$ ]]; then
            index=$((10#$choice))
            if (( index >= 1 && index <= ${#clients[@]} )); then
                SELECTED_CLIENT=${clients[index - 1]}
                return 0
            fi
        fi
        for index in "${!clients[@]}"; do
            if [[ "$choice" == "${clients[index]}" ]]; then
                SELECTED_CLIENT=$choice
                return 0
            fi
        done
        echo '选择无效，请输入列表中的编号，或输入 0 返回。'
    done
    return 1
}

add_client() {
    require_service || return
    local name
    read -r -p '新客户端名称（如 iphone）：' name || return
    valid_name "$name" || { error '名称限 1–32 位字母、数字、下划线和连字符。'; return 1; }
    [[ ! -e "$CLIENT_DIR/$name.conf" ]] || { error '客户端已存在，请选择 5 导出。'; return 1; }
    bash "$CLIENT_DIR/manage_amneziawg.sh" add "$name" --psk || return
    export_client "$name"
}

delete_client() {
    require_service || return
    local name
    select_client || return
    name=$SELECTED_CLIENT
    [[ -n "$name" ]] || return 0
    valid_name "$name" || { error '名称无效。'; return 1; }
    confirm "将撤销 $name 的 VPN 授权并删除本地导出文件，输入客户端名称确认" "$name" || { echo '已取消。'; return; }
    # 上游同时删除持久配置和实时 peer；失败时保留导出文件用于排查。
    bash "$CLIENT_DIR/manage_amneziawg.sh" remove "$name" --yes || return
    rm -f -- "$CLIENT_DIR/exports/$name.conf" "$CLIENT_DIR/exports/$name.uri" \
        "$CLIENT_DIR/exports/$name.node.png" "$CLIENT_DIR/exports/$name.native.png"
    echo '客户端已撤销，二维码及导出文件已删除。'
}

status() {
    if [[ ! -s "$SERVER_CONF" ]]; then echo '尚未完成安装。选择 1 安装或继续。'; return; fi
    systemctl --no-pager -l status awg-quick@awg0 || true
    # awg show 不输出私钥；不使用 showconf 或 dump。
    if command -v awg >/dev/null; then awg show awg0 || return; fi
    echo '注意：服务 active 仅表示服务启动，客户端仍需握手与上网测试。'
}

uninstall_all() {
    local script
    echo '将停止并卸载本工具管理的 AmneziaWG；所有 VPN 客户端将断开。'
    echo '上游会保留含密钥的卸载备份，依赖软件包和系统升级不会回滚。'
    confirm '输入 UNINSTALL 确认' UNINSTALL || { echo '已取消。'; return; }
    dependencies || return
    script=$(installer) || return
    env -u AWG_BRANCH bash "$script" --uninstall --yes || return
    if [[ -s "$SERVER_CONF" ]] || systemctl is-active --quiet awg-quick@awg0; then
        error '卸载检查未通过，保留管理入口，请检查上游输出。'; return 1
    fi
    rm -rf -- "$CLIENT_DIR/exports"
    rm -f -- /usr/local/bin/awg-menu
    rm -rf -- "$HOME_DIR"
    echo '已卸载。卸载备份如存在，位于 /root/awg_uninstall_backup_*.tar.gz。'
    exit 0
}

register_command() {
    mkdir -p "$HOME_DIR"
    if [[ "$(readlink -f -- "${BASH_SOURCE[0]}")" != "$HOME_DIR/amneziawg.sh" ]]; then
        install -m 700 -- "${BASH_SOURCE[0]}" "$HOME_DIR/amneziawg.sh"
    fi
    ln -sfn "$HOME_DIR/amneziawg.sh" /usr/local/bin/awg-menu
}

main() {
    if [[ ${1:-} == --help || ${1:-} == -h ]]; then
        echo "AmneziaWG 中文管理 v$VERSION；root 运行进入菜单；--version 查看版本。"; return
    fi
    if [[ ${1:-} == --version ]]; then echo "$VERSION"; return; fi
    [[ $# -eq 0 ]] || { error '未知参数，使用 --help。'; return 1; }
    require_root || return
    [[ -f /etc/debian_version ]] || { error '此入口支持 Debian/Ubuntu。'; return 1; }
    # 同一个菜单串行管理，避免新增/撤销授权期间同时导出。
    exec 9>/run/lock/zhuoyi-amneziawg.lock
    flock -n 9 || { error '另一个 awg-menu 正在运行，请先退出。'; return 1; }
    register_command
    local choice
    while :; do
        printf '\nAmneziaWG 中文管理 v%s\n' "$VERSION"
        printf '%s\n' '1. 安装 / 重启后继续安装 AWG 2.0' '2. 服务状态与握手信息' \
            '3. 客户端列表' '4. 新增客户端并导出二维码和节点链接' '5. 导出已有客户端（二维码和节点链接）' \
            '6. 删除客户端（撤销授权）' '7. 重启 VPN 服务' '8. 卸载 AmneziaWG' '0. 退出'
        read -r -p '请选择：' choice || break
        case "$choice" in
            1) setup || echo '操作未完成，请查看上方信息。' ;;
            2) status || echo '状态检查失败。' ;;
            3) if require_service; then bash "$CLIENT_DIR/manage_amneziawg.sh" list || echo '读取失败。'; fi ;;
            4) add_client || echo '新增或导出失败，请查看上方信息。' ;;
            5) export_client || echo '导出失败，请查看上方信息。' ;;
            6) delete_client || echo '删除未完成，请查看上方信息。' ;;
            7) if require_service; then systemctl restart awg-quick@awg0 && echo '服务已重启。' || echo '重启失败。'; fi ;;
            8) uninstall_all || echo '卸载未完成，请查看上方信息。' ;;
            0) break ;;
            *) echo '请输入菜单中的数字。' ;;
        esac
        read -r -p '按回车返回菜单…' choice || break
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
