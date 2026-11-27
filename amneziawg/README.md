# AmneziaWG 中文一键部署与客户端管理

独立于仓库中的 VPS Toolkit 主程序。默认部署 **AWG 2.0**，支持你现有的 Debian 12 / x86_64 / 6.1 内核，以及已用 bivlked 安装器创建的 `/root/awg` 服务。

## 一键进入

以 root 执行（Ubuntu 可先 `sudo -i`）：

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/zhuoyi0918/vps-toolkit/main/amneziawg.sh -o /root/zhuoyi-amneziawg.sh && bash /root/zhuoyi-amneziawg.sh
```

以后只需：

```bash
awg-menu
```

这是下载完成才执行的命令。第一次进入菜单会注册管理入口，不会自动重装现有 VPN。

## 菜单

| 选项 | 功能 |
| --- | --- |
| 1 | 安装 / 重启后继续安装 AWG 2.0 |
| 2 | 查看服务状态、peer 握手和流量 |
| 3 | 查看客户端列表 |
| 4 | 新增独立客户端，默认设置 PSK，并导出二维码 |
| 5 | 导出已有客户端的二维码和配置 |
| 6 | 撤销客户端在实时接口及持久配置中的授权，并删除本地导出文件 |
| 7 | 重启 VPN 服务 |
| 8 | 确认后卸载 AWG、移除管理入口 |

删除客户端需要输入客户端名称，卸载需要输入 `UNINSTALL`。失败时保留管理入口和排查文件，避免报告虚假的完成状态。

## 安装说明

支持 Debian/Ubuntu；上游引擎明确支持 Debian 12/13、Ubuntu 24.04/26.04，其他版本以引擎检查结果为准。需要完整虚拟机及 root 权限，不能将内核模块方案用于不允许加载模块的 OpenVZ/LXC。

安装引擎固定为 [bivlked/amneziawg-installer](https://github.com/bivlked/amneziawg-installer) 的 v6.3.11，对应提交 `a53b55ccf37c23b653a7fd21f69843bcb1323ed6`；下载后校验 SHA256：

```text
6dba0136d357a1a695294eadb05ea07f49c5462b2575d2a4e4be7d325d8fa768
```

上游自己下载的辅助脚本继续使用其内置 SHA256 校验。安装引擎从原作者仓库获取，不嵌入其他来源的二进制。底层模块和软件包仍依赖上游及系统软件源。

选项固定为 `--protocol=2.0 --no-tweaks --allow-ipv6 --no-reboot --route-all`：保留既有防火墙、系统清理及 IPv6 设置；安装必要组件、更新软件包、建立 VPN 转发/NAT。**系统升级可能安装新内核。** 安装器需要重启时保存进度并返回，用户手动执行 `reboot`，重连后再次 `awg-menu` → `1`，按提示重复直到完成。不自动重启 VPS。

VPN UDP 端口默认 51820，可首次安装时修改。商家安全组和现有防火墙需要自行放行该 UDP 端口。TCP 443 上的 Reality 与其他端口上的 AWG UDP 服务可以分别运行。

如已存在服务器配置，选择 1 会跳过安装。现有服务必须包含 `/root/awg/manage_amneziawg.sh` 及其配套文件；本工具不会把不认识的 VPN 服务自动改写为自己的格式。

## 小火箭 2.2.93 导入

选择 `5`，输入 `my_phone` 等客户端名称。输出文件位于 `/root/awg/exports/`：

| 文件 | 内容与用途 |
| --- | --- |
| `名称.node.png` | `wireguard://` 节点链接二维码，供小火箭首页扫码尝试添加节点 |
| `名称.uri` | 同一个节点链接，可以复制到小火箭首页粘贴 |
| `名称.native.png` | 完整原生 `.conf` 文本二维码，供 AmneziaWG 客户端 |
| `名称.conf` | 完整原生客户端配置，可复制内容后在小火箭首页粘贴 |

节点链接保留私钥、公钥、PSK、Address、AllowedIPs、DNS、MTU、Keepalive，以及 Jc/Jmin/Jmax、S1–S4、H1–H4、I1–I5。遇到不认识的字段（包括 AWG 3.1 特有字段）会拒绝转换，不会悄悄删掉参数后生成错误节点。

**兼容性状态：尚未在真实 Shadowrocket 2.2.93 上验证此 `wireguard://` 链接的导入与联网。** 二维码生成成功只证明其载荷正确，不能证明小火箭已识别全部 AWG 参数。先扫描终端二维码，或通过 SFTP 下载 `.node.png` 后从小火箭首页扫描。检查导入的节点中 PSK、J/S/H/I 参数与原文件一致。不要把它当普通 WireGuard 节点。

若小火箭不接受链接，可在 VPS 执行 `cat /root/awg/my_phone.conf`，在自己设备上复制完整 `[Interface]` / `[Peer]` 内容，在小火箭首页粘贴；或用 AmneziaWG 扫原生二维码做服务端连通性对照。将 `.conf` 文件通过分享菜单交给小火箭，可能只出现在“配置”页，并非节点列表。

每个设备创建独立客户端。二维码太密或终端窗口太窄时，下载 PNG 后扫描。所有二维码及配置包含凭据，只在本地生成，权限为目录 700、文件 600，不使用在线二维码网站，不开启用于公开分发配置的 HTTP 服务。

## 删除与卸载

- `6` 删除的是服务器 peer 授权；即使他人保留了二维码也无法继续使用这个 peer。仅删除导出文件不能撤销授权。若上游实时应用失败，本工具会报告失败，请修复服务后重试并检查握手情况。
- `8` 使用固定版本引擎执行卸载；会停止 VPN、移除其配置和服务等组件。引擎默认保留 `/root/awg_uninstall_backup_*.tar.gz`，其中含私钥，按需自行保管或删除。
- 卸载不回滚系统软件升级，也不保证删除已安装的通用编译器和依赖；上游安装器的完整卸载范围见其文档。
- 旧版本上游在安装时创建的第三方备份不由本工具删除。

## 验证

```bash
bash -n amneziawg.sh
python3 -m unittest discover -s amneziawg/tests -v
```

测试覆盖配置转换、密钥与混淆参数保留、拒绝未知字段/多 peer/错误输入、凭据文件权限、二维码载荷，以及删除成功/失败/取消和重启继续安装状态。测试不安装内核模块、不修改宿主网络。发布前未在用户 VPS 上重新执行安装或卸载；实际联网及小火箭扫码需设备验证。

## 来源与许可

本入口遵循仓库 MIT 许可；部署和 peer 管理调用 **bivlked** 的 MIT 许可 [amneziawg-installer](https://github.com/bivlked/amneziawg-installer)（运行时下载，版权归原作者），底层协议来自 [amnezia-vpn](https://github.com/amnezia-vpn)。本项目不是 Amnezia 或 Shadowrocket 官方项目。
