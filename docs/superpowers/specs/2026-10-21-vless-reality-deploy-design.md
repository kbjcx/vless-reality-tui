# VLESS + REALITY 一键部署工具 · 设计文档

- 日期：2026-10-21
- 状态：已评审通过
- 版本：v1.0

---

## 1. 背景与目标

在 Debian 服务器上一键部署 **VLESS + REALITY**（Xray-core）服务，用一个零依赖的纯 bash TUI
把部署过程简化、美化，最终产出可直接导入客户端的分享链接与二维码。

目标用户是**个人自用**：单台 Debian 服务器、单用户，SSH 上去跑一次即可。

核心目标：

1. **一键** —— 不预装任何第三方 TUI 库，把一个文件放到服务器上就能跑。
2. **可视化** —— 用彩色 TUI 取代一屏 `apt install` 日志，让每一步的状态一目了然。
3. **可维护** —— 放进 GitHub 仓库长期维护，界面改动不得影响部署逻辑。

---

## 2. 需求确认结论（决策记录）

本节记录 2026-10-21 的需求澄清结果，是后续所有设计决策的依据。

| 维度 | 决策 | 理由 |
|---|---|---|
| 使用场景 | 个人自用，单服务器单用户 | 不做多用户、订阅、面板 |
| 部署形态 | 原生二进制 + systemd | 资源占用低、开机自启、升级回滚简单 |
| TUI 技术栈 | 纯 bash + ANSI 转义序列，零外部依赖 | 「一键」= 拷一个文件就能跑 |
| 交互形态 | 向导 + 事后可唤起管理菜单 | 部署是主路径，管理是长尾需求 |
| 代码结构 | 模块化源码 + 构建产出单文件分发物 | 分发要单文件，维护要分层 |
| 分发形态 | GitHub 仓库，模块化源码 + `dist/install.sh` + CI 校验 | 兼顾一键分发与长期维护 |

---

## 3. 非目标（YAGNI）

明确**不做**以下内容，避免范围蔓延：

- Web 面板 / 用户管理 / 订阅系统
- Docker 部署路径
- 自动更新守护进程（手动触发即可）
- 多用户 / 多设备配额管理
- 域名解析与证书签发 —— REALITY 的核心优势就是不依赖证书
- 修改 SSH 端口等与本项目无关的系统设置

---

## 4. 架构与模块边界

### 4.1 依赖方向

严格单向、无环：

```
install.sh ──> deploy.sh ──> core.sh
      │ └────────> tui.sh
      ├────────> client.sh ──> core.sh
      └────────> tui.sh
core.sh ──> tui.sh
```

**硬约束**：`lib/tui.sh` 不依赖任何其它模块，不含任何业务逻辑。
这是"改界面不碰部署逻辑"的唯一保障，必须在 code review 中守住。

### 4.2 职责划分

| 模块 | 职责 | 不负责 |
|---|---|---|
| `lib/tui.sh` | 颜色、边框、菜单、输入、确认、spinner、面板 | 任何业务判断、任何系统调用 |
| `lib/core.sh` | 环境探测、IP/端口探测、密钥生成、状态读写、URL 编码 | 部署动作、界面渲染 |
| `lib/deploy.sh` | Xray 安装、配置生成、systemd、防火墙、BBR | 界面渲染、客户端物料 |
| `lib/client.sh` | 分享链接、二维码、客户端配置导出 | 服务端配置 |
| `install.sh` | 参数解析、预检、向导编排、管理菜单 | 具体实现细节 |

### 4.3 状态的单一真相

- **Xray 的 `config.json` = 运行时唯一真相**（真实生效的配置）
- 工具侧另存 `/etc/vless-reality/deploy.env`（权限 600）作为**工具自己的状态**，
  供管理菜单读取、展示、轮换密钥
- 两者由 `deploy.sh` **单向生成**：写完 `config.json` 后同步写 `deploy.env`
- **绝不反向解析 JSON** —— 不用 `grep` 抓 JSON 字段，也因此不引入 `jq` 依赖

### 4.4 安装落点

| 路径 | 内容 | 权限 |
|---|---|---|
| `/usr/local/bin/xray` | Xray 内核（官方 `install-release.sh`） | 755 |
| `/usr/local/etc/xray/config.json` | 服务端配置 | 644 |
| `/etc/xray/` | 官方安装脚本附带的 `geosite.dat` / `geoip.dat`（**非依赖项**，本工具的配置不引用 geoip） | 644 |
| `/etc/vless-reality/deploy.env` | 工具状态 | **600** |
| `/root/vless-reality/` | 客户端导出物料 | 700 |
| `/var/log/xray/` | `access.log` / `error.log` | 按运行用户授权 |

---

## 5. 目录结构

```
vless-reality-deploy/          ← GitHub 仓库根
├── install.sh                 # 唯一入口：参数解析 → 预检 → 向导
├── uninstall.sh               # 卸载与回滚
├── build.sh                   # lib/ → dist/install.sh 单文件构建
├── demo.sh                    # 纯预览 TUI 外观，完全不碰系统
├── lib/
│   ├── tui.sh                 # 零依赖 TUI 组件库
│   ├── core.sh                # 环境探测 / 网络 / 密钥 / 状态
│   ├── deploy.sh              # Xray 安装、配置、systemd、防火墙、BBR
│   └── client.sh              # 分享链接、二维码、客户端配置
├── test/
│   ├── unit.sh                # 纯函数断言
│   └── integration-debian.sh  # 容器内端到端（需 Docker）
├── dist/
│   └── install.sh             # 构建产物，提交进仓库
├── docs/
│   └── superpowers/specs/
└── .github/workflows/ci.yml
```

---

## 6. TUI 组件库规范（`lib/tui.sh`）

### 6.1 组件清单

| 组件 | 作用 |
|---|---|
| `tui_init` | 探测 TTY / 颜色 / 宽度 / Unicode 能力，初始化调色板 |
| `tui_banner` | 顶部圆角标题框，主标题 + 副标题 |
| `tui_section` | 区块标题（`●` + 下划线分隔） |
| `tui_box` / `tui_box_line` / `tui_box_end` | 圆角内容框 |
| `tui_panel` | 键值结果面板（部署完成时展示参数） |
| `tui_menu` | 箭头键菜单：`↑↓` 移动、数字直选、`Enter` 确认、`q` 取消。数字输入**累积成缓冲区**（如按 `1` 后 0.35 秒内无后续数字则判定为单数字选中，否则继续累积），`Enter` 时若缓冲区非空则按编号选中，否则确认当前高亮项 |
| `tui_select` | 带默认项的菜单（通过 `TUI_MENU_DEFAULT_INDEX` 传默认值） |
| `tui_input` / `tui_input_secret` | 单行输入，支持默认值与占位提示 |
| `tui_confirm` | 确认（`Y/n`），默认值可配 |
| `tui_run` | 带 spinner 的命令执行，**失败时自动打印捕获的输出** |
| `tui_ok` / `tui_warn` / `tui_err` / `tui_info` / `tui_tip` | 彩色状态行 |
| `tui_kv` | 键值对行 |
| `tui_pause` | 等待回车 |
| `tui_dwidth` / `tui_pad` / `tui_repeat` | 文本宽度计算与补白 |

### 6.2 视觉规范

- **调色板**：256 色。成功=绿 114、错误=红 203、警告=黄 179、信息=蓝 110、强调=青 80、
  正文=白 253、次要=灰 244
- **边框**：圆角 `╭ ╮ ╰ ╯ ─ │`，Unicode 不可用时降级为 `+ - |`
- **中文对齐**：全角字符按 **2 列**计算宽度。实现方式为自写 `tui_dwidth`，
  对 CJK / 全角区段按 2 累加，其余按 1。**不依赖 `wc -m`**（其行为随 locale 变化不可靠）
- **宽度**：取 `tput cols`，钳制在 46–100 列之间
- **重绘**：菜单用 `\033[<n>A\033[J` 原地刷新，`n` 为本次绘制的行数

### 6.3 降级策略

| 场景 | 行为 |
|---|---|
| 交互式 TTY | 完整彩色 TUI + 方向键菜单 |
| 非 TTY（`nohup` / `curl \| bash` / CI） | 关颜色与 spinner，降级为**编号列表 + 提示符**，日志风格输出 |
| `TERM=dumb` | 同非 TTY |
| `NO_COLOR` 置位 | 保留布局，去掉颜色 |

**关键约束**：非 TTY 下 `tui_menu` 仍打印完整带序号的列表并请求输入序号，
保证 `bash install.sh < /dev/null` 不会挂死。

---

## 7. 部署向导流程（`install.sh` 默认路径）

```
0. 预检    → root / 系统 / 架构 / 端口占用 / 公网 IP 多源回退 / 已部署检测
1. 参数    → 端口、伪装目标、备注名、密钥与 UUID（每项有默认值，Enter 即采纳）
2. 确认    → 参数面板 + 摘要，确认或取消
3. 执行    → 逐步 spinner，失败即刻中止并保留旧配置
4. 产出    → 分享链接 + 终端二维码 + PNG + 客户端配置 + 结果面板
5. 收尾    → 询问是否进入管理菜单
```

### 7.1 第 0 步 · 预检

- root 检查：非 root 立即退出，提示用 `sudo`
- 系统检查：非 Debian **警告但继续**（Ubuntu 与 Debian 同源，一般可直接用）
- 端口占用：若 443 被占用，列出占用进程，给出「换端口 / 改用随机高位端口」两个选项
- 公网 IP：多源回退（ipify → ifconfig.me → icanhazip → ipinfo.io → ipip.net）；
  全部失败则允许手填，否则回退本机 IP 并明确提示
- 依赖补齐：TLS 1.3 探测需要 `openssl`，二维码需要 `qrencode`。
  缺失时在预检阶段自动 `apt-get install`（`openssl` 必需；`qrencode` 缺失只跳过二维码，不阻断流程）
- 已部署检测：已有 `deploy.env` 时提示可选择「重新部署 / 保留现有 / 取消」

### 7.2 第 1 步 · 伪装目标选择

候选列表（要求支持 TLS 1.3 + H2）：

```
www.microsoft.com  dl.google.com  www.apple.com
one.one.one.one    www.cloudflare.com  time.akamai.com  addons.mozilla.org
```

并发探测每个候选的 **TLS 1.3 支持**与**连通延迟**，展示后按延迟升序排列：

```
  ▸ www.microsoft.com    TLS1.3 ✔   12ms
  ▸ dl.google.com        TLS1.3 ✔   45ms
  ▸ www.apple.com        TLS1.3 ✘    ?
```

### 7.3 第 3 步 · 执行序列

```
① 安装 Xray 内核   官方 install-release.sh，幂等；已装则跳过并提示当前版本
② 生成密钥与 UUID  xray x25519 / xray uuid
③ 写 config.json  → xray run -test 校验 → 通过才原子替换
④ systemd         enable --now + restart；读出 User= 授权日志目录
⑤ 防火墙放行端口   ufw active → ufw allow；否则 nft / iptables；都没有则明确告知
⑥ BBR 调优        仅当内核支持 bbr，写 sysctl 持久化
```

---

## 8. 管理菜单（`--menu`）

```
① 重新部署（重跑向导）        ⑤ 更新 Xray 内核
② 查看配置 / 链接 / 二维码      ⑥ 网络调优（BBR / 防火墙复查）
③ 重启服务                    ⑦ 轮换密钥与 UUID
④ 实时日志（tail -f）          ⑧ 卸载
⑨ 退出
```

菜单项在未部署状态下应被禁用或给出明确提示，而不是直接失败。

---

## 9. Xray / REALITY 配置规范

### 9.1 密钥生成的版本兼容

`xray x25519` 在不同版本输出格式不同：

- 旧版：`Private key: <priv>` / `Public key: <pub>`
- 新版 v25.x：`PrivateKey: <priv>` / `Password: <pub>`

解析必须用宽松正则分别捕获 `private` 与 `public|password`，**两种格式都认**。

### 9.2 服务端配置模板

```json
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "<UUID>", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "<SNI>:443",
          "xver": 0,
          "serverNames": ["<SNI>"],
          "privateKey": "<PRIV>",
          "shortIds": ["<SID>"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",
      "settings": { "domainStrategy": "UseIP" } },
    { "tag": "block", "protocol": "blackhole",
      "settings": { "response": { "type": "http" } } }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field",
        "ip": ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12",
               "192.168.0.0/16", "fc00::/7", "fe80::/10"],
        "outboundTag": "block" }
    ]
  }
}
```

### 9.3 三个关键决策

1. **私网封禁用字面 CIDR，不用 `geoip:private`** —— 不依赖 `geoip.dat` 是否存在，
   避免"内核起来了但路由规则报错"。客户端配置同样不用 geoip。
2. **`domainStrategy: IPIfNonMatch`** —— 让私网封禁对域名目标也真正生效
   （`AsIs` 下域名不解析，规则不触发）。
3. **用 `target` 而非旧别名 `dest`** —— `target` 自 1.8 起支持，官方安装脚本装的是最新版。

### 9.4 客户端配置

入站：`socks 127.0.0.1:1080`、`http 127.0.0.1:1081`
出站：`vless` + `reality`，`fingerprint: chrome`，含 `serverName` / `publicKey` / `shortId` / `spiderX: /`

### 9.5 分享链接格式

```
vless://<UUID>@<IP>:<PORT>?encryption=none&flow=xtls-rprx-vision
        &security=reality&sni=<SNI>&fp=chrome&pbk=<PUB>&sid=<SID>
        &type=tcp&headerType=none#<REMARK>
```

---

## 10. CLI 契约

```
install.sh [选项]
  -y, --yes          全自动无交互（用默认值）
  -p, --port <端口>   指定监听端口
  -s, --sni <域名>    指定 REALITY 伪装目标
  -n, --name <备注>   分享链接备注
      --uuid <UUID>   指定 UUID（默认自动生成）
  -m, --menu          直接进入管理菜单
      --status        只做状态自检并打印
      --uninstall     卸载
  -h, --help          帮助
```

`--yes` 模式下任一步失败**立即中止**，绝不带着半成品继续往下跑。

---

## 11. 错误处理矩阵

| 故障 | 处理 |
|---|---|
| 非 root | 立即退出，提示用 `sudo` |
| 非 Debian | 警告但继续（Ubuntu 同源可用） |
| 443 被占用 | 列出占用进程，建议换端口或自动改随机高位端口 |
| `xray run -test` 不过 | **不替换**旧配置，原样输出 xray 报错 |
| systemd 启动失败 | 自动展示 `journalctl -u xray -n 30` |
| 日志目录不可写 | 按 `systemctl show xray -p User` 取真实运行用户授权 |
| 探测不到公网 IP | 允许手填；否则回退本机 IP 并明确提示 |
| 无任何防火墙工具 | 明确告知"未改动防火墙，请自行放行端口" |
| 中途 Ctrl-C | `trap` 清理临时文件；已完成的步骤不回滚（配置写入是原子的） |
| `qrencode` 装不上 | 跳过二维码，明确提示；不影响主流程 |

所有失败路径统一 `tui_err` + 非零退出码。

---

## 12. 幂等性与安全

- 重复运行 `install.sh` 属于**重新部署**而非叠加部署：
  不产生重复 systemd unit，不产生重复防火墙规则
- 所有文件写入先落临时文件再原子 `mv`
- 配置在替换前必须通过 `xray run -test`，不通过则保留旧配置
- 私钥与状态文件权限 600，状态目录 700
- 工具**不修改**与本项目无关的系统设置

---

## 13. 分发与 CI

### 13.1 构建

`build.sh` 按依赖顺序把 `lib/*.sh` 内联进 `dist/install.sh`，加版本戳，产物提交进仓库。

内联顺序固定为 `tui.sh → core.sh → client.sh → deploy.sh`（函数定义顺序不影响运行期调用，
固定顺序只为让构建产物可复现、diff 稳定）。

用户侧一行命令（**刻意不用 `curl | bash` 直接管到 root**，让用户能先看一眼再执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/<user>/<repo>/main/dist/install.sh -o install.sh && sudo bash install.sh
```

### 13.2 CI（`.github/workflows/ci.yml`）

1. `bash -n` 对所有 `.sh` 做语法检查
2. `shellcheck`（severity ≥ warning）静态检查
3. **dist 同步检查**：重新构建后 `git diff --exit-code dist/install.sh` ——
   防止改了 `lib/` 却忘了重新构建

---

## 14. 测试策略

| 层 | 内容 | 何时跑 |
|---|---|---|
| 语法层 | `bash -n` 全部 `.sh` | CI 必跑 |
| 单元层 | 纯函数断言：`tui_dwidth`（中文宽度）、`tui_pad`、`urlencode`、`random_hex`、配置模板 JSON 合法性 | CI 必跑 |
| 集成层 | `test/integration-debian.sh` 在 Debian 容器里跑完整部署 | 需 Docker，CI 可选 job |

---

## 15. 卸载

`uninstall.sh`：

1. 停止并禁用 `xray.service`
2. 备份并移除 `config.json`（备份到 `/root/vless-reality/backup/`）
3. 撤销防火墙规则（ufw delete / nft delete rule / iptables -D）
4. 移除 sysctl 调优文件
5. 询问是否删除客户端导出目录
6. 默认**保留** `/etc/vless-reality/deploy.env`（`--purge` 才删）
7. 内核二进制默认保留并提示

---

## 16. 已知风险与未验证项

- **Debian 真机端到端部署未在本环境验证** —— 开发环境为 Windows，无 Debian 可用。
  已验证项：`bash -n` 语法检查、TUI 渲染（`demo.sh`）。
  未验证项：实际 apt 安装、systemd 启停、防火墙放行、REALITY 握手连通性。
  README 必须明确标注这一点。
- `xray x25519` 输出格式随版本变化，已按宽松正则兼容，但未来版本若再次变更需复查。
- nftables 规则在部分 Debian 12+ 环境下需持久化到 `/etc/nftables.conf` 才在重启后保留，
  工具应检测并提示。
- REALITY 的伪装目标需要与本机不同 ASN 才更抗主动探测，候选列表为通用推荐，
  不保证对所有服务器最优。
