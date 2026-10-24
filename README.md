# vless-reality-tui

纯 bash + 零第三方依赖的 VLESS + REALITY 一键部署工具：TUI 向导、事后管理菜单、单文件 install.sh。

一个面向 **Debian** 服务器的 VLESS + REALITY 一键部署工具：交互式向导负责预检、
生成 REALITY 密钥、写入服务端配置、注册 systemd 服务、放行防火墙端口，
最后导出一份可直接导入客户端的分享链接与二维码。

所有交互都在终端里完成（TUI），不依赖任何外部框架；仓库同时提供一个
**单文件分发版**（`dist/install.sh`），可以只下载一个文件就跑起来。

> ⚠️ 请先读 [验证状态声明](#验证状态声明)：这个工具的**大部分环节没有在真实
> Debian 真机上验证过**，那一节逐条列出了哪些结论可信、哪些不可信。

## 特性

- **交互式 TUI 向导**：预检、端口选择、REALITY 伪装目标（SNI）探测与选择、
  密钥生成、服务注册、防火墙放行一步步引导，不需要手改配置文件。
- **REALITY 伪装目标探测**：自动探测可达的伪装站点并让用户挑选，
  避免出现"客户端连得上但一眼看出是代理"的情况。
- **分享链接自动生成**：`vless://` 链接一行给出（含 `pbk` / `sni` / `fp` / `sid`），
  同时导出标准客户端 JSON 与终端二维码。
- **超宽内容不撑破边框**：分享链接常有 150+ 字符，放不进内容框时改为
  **整行输出**（终端软换行不影响复制出来的内容）。
- **管理菜单**：部署完成后可随时重跑向导、查看配置与分享链接、重启服务、
  看实时日志、更新 Xray 内核、网络调优、轮换密钥、卸载。
- **幂等与可回滚**：状态写入 `/etc/vless-reality/deploy.env`（单一真相），
  重复部署不会留下半成品；卸载前自动备份配置。
- **网络受限也能装**：GitHub 只有 IPv4、没有公网 IPv4 的机器照样能装 ——
  支持 `--proxy` 走代理、`--mirror` 走镜像、`--local` 用离线安装包；
  内核安装包用官方 `.dgst` 做 SHA-256 校验，**不再执行任何第三方脚本**。
- **可移植的单文件版**：`bash build.sh` 把 `install.sh` 与 `lib/` 打包成一个
  `dist/install.sh`，拷贝到任何 Debian 机器上 `sudo bash install.sh` 即可。
- **自带测试**：`bash test/unit.sh` 是纯 bash 的单元测试套件，
  `bash test/integration-debian.sh` 在 Debian 容器里跑端到端流程。
- **界面可预览**：`bash demo.sh` 离线渲染 TUI 的真实效果，不触碰系统任何配置
  （见[界面预览](#界面预览)）。

## 快速开始

### 方式一：clone 仓库运行

```bash
git clone https://github.com/kbjcx/vless-reality-tui.git
cd vless-reality-tui
sudo bash install.sh
```

### 方式二：下载单文件（推荐给不方便装 git 的机器）

先下载、再执行，**不用管道**：

```bash
curl -fsSL https://raw.githubusercontent.com/kbjcx/vless-reality-tui/main/dist/install.sh -o install.sh
sudo bash install.sh
```

> ⚠️ 命令里是 `sudo bash install.sh`，**不是**直接用 `./install.sh` 执行 ——
> `curl -o` 下载下来的文件**没有执行位**，所以 `./install.sh` 会 Permission denied。
> （仓库里的 `install.sh` 提交模式是 `100755`，clone 下来就带执行位；
> 但 `bash install.sh` 两种情况都成立。）

### 一行命令（最常用）

```bash
curl -fsSL https://raw.githubusercontent.com/kbjcx/vless-reality-tui/main/dist/install.sh -o install.sh && sudo bash install.sh
```

## curl 单文件方式的完整命令

```bash
# 1) 下载单文件分发版（dist/install.sh 由 build.sh 生成）
curl -fsSL https://raw.githubusercontent.com/kbjcx/vless-reality-tui/main/dist/install.sh -o install.sh

# 2) 以 root 执行（部署要写 /etc、注册 systemd 服务、放行防火墙端口）
sudo bash install.sh

# 3) 全自动模式：用内置默认值，不再交互
sudo bash install.sh -y

# 4) 只想看状态（只读，不需要 root）
sudo bash install.sh --status
```

> ⚠️ `dist/install.sh` 是**单文件分发版**，它**不含** `uninstall.sh` ——
> 卸载请看 [卸载说明](#卸载说明)。

## 界面预览

下面是 `bash demo.sh` 的**真实输出**（原样剥掉 ANSI 颜色码）——
`demo.sh` **不触碰系统任何配置**，纯离线渲染，可以放心随便跑：

```text
  ╭────────────────────────────────────────────────────────────────────────────╮
  │ VLESS + REALITY 部署工具                                                   │
  │ TUI 界面预览 · 本脚本不会修改系统任何配置                                  │
  ╰────────────────────────────────────────────────────────────────────────────╯

  ● 区块标题与状态行
  ────────────────────────────────────────────────────────────────────────────
  ℹ 这是一条信息提示
  ✔ 这是一条成功提示
  ▲ 这是一条警告提示
  ✖ 这是一条错误提示
  ▷ 这是一条补充说明
  ▸ 这是一步进行中的操作

  ● 键值对与结果面板
  ────────────────────────────────────────────────────────────────────────────
  服务器地址                                             203.0.113.10
  监听端口                                               443

  ╭ 示例配置 ──────────────────────────────────────────────────────────────────╮
  │ 地址               203.0.113.10:443                                        │
  │ UUID               8f3a1c22-4b6d-4e51-9b2c-7a0e5d3f1c88                    │
  │ SNI                www.microsoft.com                                       │
  │ 公钥 pbk           xQ0G2k7F0l3mN8pQ2rS5tU7vW9xY1zA3bC5dE7fG                │
  ╰────────────────────────────────────────────────────────────────────────────╯

  ● 超宽内容（放不下就不画框，整行输出）
  ────────────────────────────────────────────────────────────────────────────

  ● 分享链接（示例）
  ────────────────────────────────────────────────────────────────────────────
  vless://8f3a1c22-4b6d-4e51-9b2c-7a0e5d3f1c88@203.0.113.10:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=xQ0G2k7F0l3mN8pQ2rS5tU7vW9xY1zA3bC5dE7fG&sid=1a2b3c4d&type=tcp#my-node

  ● 菜单（方向键移动 / 数字直选 / Enter 确认 / q 取消）
  ────────────────────────────────────────────────────────────────────────────

  ● 示例菜单
  ────────────────────────────────────────────────────────────────────────────
      1) 部署 VLESS + REALITY 服务
      2) 查看客户端分享链接
      3) 重启服务
      4) 实时日志
      5) 退出
  请输入序号 [1-5]: 
```

两处值得注意的细节：

- **框线宽度恒为 80 列**：每一行的显示宽度都精确等于 `TUI_WIDTH`，
  框线才合得拢（仓库自带 `tui_dwidth` 按显示宽度算，CJK 记 2 列）。
- **超宽内容不撑破边框**：真实分享链接有 150+ 字符（上面示例里那条有 225 列），
  放不进内容框就**整行输出**——终端软换行不影响复制出来的内容。
  在窄屏上这条会横向滚动，这是**故意**的：要保证复制出来的链接一个字符都不少。
## 目录结构

```
.
├── LICENSE                       # 开源协议（MIT）
├── install.sh                    # 入口：参数解析、预检、调用向导
├── uninstall.sh                  # 卸载与清理（带备份）
├── build.sh                      # 把 install.sh + lib/ 打成单文件 dist/install.sh
├── demo.sh                       # TUI 界面预览（不触碰系统任何配置）
├── lib/
│   ├── tui.sh                    # 纯界面层：颜色、宽度计算、框线、菜单、输入、确认
│   ├── core.sh                   # 基础层：常量、状态读写、原子写文件、依赖探测
│   ├── deploy.sh                 # 部署层：向导、目标探测、执行序列、管理菜单
│   └── client.sh                 # 客户端层：分享链接、客户端 JSON、二维码导出
├── test/
│   ├── lib.sh                    # 极简断言库（纯 bash，不依赖 bats）
│   ├── unit.sh                   # 单元测试套件
│   ├── integration-debian.sh     # Debian 容器内端到端集成测试
│   └── helpers/                  # 测试用的 TUI 交互 helper
├── dist/
│   └── install.sh                # 构建产物（单文件分发版）
└── docs/superpowers/             # 设计稿与实施计划
```

运行期落在系统里的路径：

| 路径 | 用途 |
| --- | --- |
| `/etc/vless-reality/deploy.env` | 部署状态（单一真相，权限 600） |
| `/root/vless-reality/` | 客户端导出目录（分享链接、客户端 JSON、二维码） |
| `/usr/local/etc/xray/config.json` | 服务端配置 |

## CLI 参数

```
sudo bash install.sh [选项]
```

| 选项 | 说明 |
| --- | --- |
| `-y`, `--yes` | 全自动无交互，使用内置默认值 |
| `-p`, `--port <端口>` | 指定监听端口（默认 443） |
| `-s`, `--sni <域名>` | 指定 REALITY 伪装目标 |
| `-n`, `--name <备注>` | 指定分享链接备注 |
| `--uuid <UUID>` | 指定 UUID（默认自动生成） |
| `--addr <地址>` | 指定对外地址（NAT 后的服务器用；默认自动探测公网 IP） |
| `--mirror <前缀>` | GitHub 镜像前缀（例：`https://gh.llkk.cc/`） |
| `--proxy <地址>` | 下载走 HTTP/SOCKS5 代理（例：`http://127.0.0.1:7890`） |
| `--local <zip>` | 使用本地已有的 Xray 离线安装包（完全不联网） |
| `-m`, `--menu` | 直接进入管理菜单 |
| `--status` | 查看运行状态并退出（只读，不需要 root） |
| `--uninstall` | 卸载并清理 |
| `-h`, `--help` | 显示本帮助 |

常用组合：

```bash
sudo bash install.sh -y -p 443 -s www.microsoft.com -n my-node
sudo bash install.sh --status
sudo bash install.sh --menu
```

## 网络受限环境下的安装

Xray 内核要从 GitHub 下载。而 GitHub 的**主站与 release 资源**
（`github.com`、`api.github.com`、`objects.githubusercontent.com`）**目前都只有 IPv4** ——
如果你的机器**没有公网 IPv4**（纯 IPv6 的云主机、落在 `100.64.0.0/10` 这类 CGNAT 网段、
或出站被防火墙挡住），下载必然失败。

本工具为此准备了三条互不依赖的走法，任选其一：

| 场景 | 命令 |
| --- | --- |
| 本机有可用代理 | `sudo bash install.sh --proxy http://127.0.0.1:7890` |
| 想走 GitHub 镜像 | `sudo bash install.sh --mirror https://gh.llkk.cc/` |
| 机器完全不能上网 | `sudo bash install.sh --local /root/Xray-linux-64.zip` |

### 三条走法分别做了什么

- **代理**（`--proxy`）：所有下载（内核压缩包 + 官方校验文件）都走这个代理。
  支持 `http://` / `https://` / `socks5://` / `socks5h://` / `socks4://`。
- **镜像**（`--mirror`）：镜像前缀会拼在原始下载地址前面，
  例如 `https://gh.llkk.cc/` + `https://github.com/...`。
  **没指定** `--mirror` 时，工具在直连失败后也会**自动**依次尝试内置镜像。
- **离线包**（`--local`）：指向一个事先下载好的 `Xray-linux-<架构>.zip`，
  工具**完全不联网**也能装好内核。

### 架构名对照

离线包的文件名必须与目标机器的架构对得上：

| `uname -m` | 压缩包名 |
| --- | --- |
| `x86_64` | `Xray-linux-64.zip` |
| `aarch64` | `Xray-linux-arm64-v8a.zip` |
| `armv7l` | `Xray-linux-arm32-v7a.zip` |
| `i686` | `Xray-linux-32.zip` |
| `s390x` | `Xray-linux-s390x.zip` |

不确定架构时，在**目标机器**上跑 `uname -m` 即可。

### 安装包的校验

下载到的压缩包会用官方发布的 `.dgst`（内含 SHA-256）校验：

- 校验文件**优先从直连 GitHub 取** —— 镜像站一旦被污染，它给的包和校验文件会一起被改，
  只有直连取到的校验文件才能发现篡改；
- 直连取不到时退回同源，并**明确提示「安装包未经校验」**；
- 校验**不通过时直接中止**，不会把来路不明的二进制装成 root 可执行的文件。

### 内核安装不再执行第三方脚本

从 **v1.1** 起，工具**不再下载并以 root 执行** `XTLS/Xray-install` 的 `install-release.sh`
（旧版会下载 `main` 分支上的脚本直接跑，且**没有校验和校验** —— 该风险已在本版消除）。
现在的流程是：自己下载 release 压缩包 → 校验 SHA-256 → 解压 → 安装二进制 →
创建 `xray` 用户 → 写 systemd unit → 启动服务。全程只跑本仓库自己的代码。

### 只有 IPv6 的服务器注意

如果你的机器**只有 IPv6、没有公网 IPv4**，那么：

- 内核安装照常可以完成（走镜像或离线包）；
- 但**客户端必须也支持 IPv6** 才能连上这台机器 —— 分享链接里的地址是 IPv6，
  形如 `vless://uuid@[2001:db8::1]:443?...`（IPv6 在链接里要加方括号）；
- 此时请用 `--addr` **显式指定**这台机器的 IPv6 地址，例如
  `sudo bash install.sh --addr 2001:db8::1`。
  不指定的话，工具可能探测到 `100.64.0.0/10` 这类**内网/CGNAT 地址**，
  写进分享链接后客户端根本连不上。

## 部署向导

`sudo bash install.sh` 进入交互式向导，流程如下：

1. **环境预检**
   - 必须是 Debian（读 `/etc/os-release` 判定）；
   - 必须有 `systemd`（`systemctl`）与 `curl`；
   - 自动补齐 `openssl`、`qrencode`（缺失时用 `apt-get` 安装）；
   - 探测对外地址：优先用 `--addr` 指定的地址，否则探测公网 IP，
     探测失败时回退到本机地址并提示你用 `--addr` 手工指定。
2. **部署参数**
   - 监听端口（默认 443）。端口被占用时向导会问你要怎么处理：换端口 / 换协议 / 继续；
   - REALITY 伪装目标（SNI）：自动探测候选站点并让你从列表里挑一个。
3. **执行部署**（六步）
   - ① 安装 Xray 内核
   - ② 生成 REALITY 密钥与 UUID
   - ③ 生成服务端配置
   - ④ 配置 systemd 服务（`systemctl enable --now xray`）
   - ⑤ 放行防火墙端口 `<port>/tcp`（ufw / iptables / nft，失败**不**中止部署，
     但会写进最终的「部署完成」面板）
   - ⑥ 网络调优（BBR 等，非致命）
4. **部署完成**
   - 打印部署面板（配置路径、客户端导出目录等）；
   - 打印**分享链接**（`vless://…` 一整行，**不在框里** —— 长度超过内容框净宽，
     整行输出才能原样复制）；
   - 若装了 `qrencode`，额外打印终端二维码。

## 管理菜单

`sudo bash install.sh --menu`（或部署完成后自动进入）提供九项：

| # | 菜单项 | 作用 |
| --- | --- | --- |
| 1 | 重新部署（重跑向导） | 再走一遍部署流程（幂等） |
| 2 | 查看配置 / 分享链接 / 二维码 | 打印分享链接（整行输出）与二维码 |
| 3 | 重启服务 | `systemctl restart xray` |
| 4 | 实时日志（`tail -f`） | 跟踪 xray 日志 |
| 5 | 更新 Xray 内核 | 重新执行内核安装流程 |
| 6 | 网络调优（BBR / 防火墙） | 开启 BBR、调整防火墙规则 |
| 7 | 轮换密钥与 UUID | 生成新的一组 REALITY 密钥与 UUID 并更新配置 |
| 8 | 卸载 | 转入卸载流程（见 [卸载说明](#卸载说明)） |
| 9 | 退出 | 退出管理菜单 |

## 客户端导入

部署完成后，`/root/vless-reality/` 目录下会有：

| 文件 | 内容 |
| --- | --- |
| `client.json` | 通用客户端配置 |
| `qrcode.txt` | 终端二维码（需要 `qrencode`） |
| `qrcode.png` | 二维码图片（需要 `qrencode`） |

**最省事的做法**：把终端里打印的那一整行 `vless://…` 分享链接复制下来，
粘贴到客户端的「从剪贴板导入」里。

各客户端的导入方式：

| 客户端 | 导入方式 |
| --- | --- |
| **v2rayN**（桌面版） | 菜单「服务器 → 添加 [VLESS] 服务器」→ 从剪贴板导入分享链接；或「服务器 → 分享链接」里点二维码扫描 |
| **v2rayNG**（Android） | 右上角 `+` → 「从剪贴板导入」，或扫 `qrcode.png` 的二维码 |
| **Clash Verge**（桌面版） | 需要 Clash Meta / Mihomo 内核；在配置里新建 `proxies:` 条目，或先用订阅转换工具把分享链接转成订阅 |
| **Shadowrocket**（iOS/macOS） | 右上角 `+` → 「从剪贴板导入」，或扫二维码 |
| **Hiddify**（Android / iOS / 桌面） | 「添加配置 / 配置档」→ 从剪贴板导入或扫二维码 |

> ⚠️ Clash 原版内核**不支持** REALITY 的 `xtls-rprx-vision` 流程，
> 必须用 **Clash Verge Rev / Mihomo** 内核。
>
> ⚠️ 导入后如果连不上，先看 [常见问题](#常见问题) 里的端口、防火墙与 BBR 三条。

## 常见问题

**Q：提示端口被占用 / 部署完客户端连不上？**

- 先确认服务在跑：`systemctl status xray`；
- 再确认端口在监听：`ss -ltn | grep 443`（没有 `ss` 时用 `netstat -ltn`）；
- 云服务器还要检查**安全组 / 云防火墙**是否放行 `<port>/tcp` ——
  那是厂商侧的规则，工具改不了。

**Q：防火墙没放行 / 放行失败？**

- 工具按 `ufw` → `iptables` → `nft` 的顺序尝试，**失败不中止部署**，
  失败状态会出现在「部署完成」面板里；
- 请自己确认一次：`ufw status`（或 `iptables -S` / `nft list ruleset`）；
- 放行之后记得重启服务：`systemctl restart xray`。

**Q：没有 BBR / 想开 BBR？**

- 管理菜单第 6 项「网络调优（BBR / 防火墙）」可以开启 BBR；
- BBR 需要内核支持（Linux 4.9+）且需要 `sysctl` 可写；
  内核不支持时这一步会被跳过，**不影响部署**；
- 开启后同样建议重启一次服务。

**Q：没有二维码 / 二维码是空的？**

- 二维码依赖 `qrencode`：预检时会尝试用 `apt-get` 装它；
  装不上时仍然可以正常部署，只是没有二维码；
- 手动补装：`apt-get install -y qrencode`，然后在管理菜单里重新查看；
- 就算没有二维码，也**不影响**用分享链接导入 —— 分享链接本身就是一整行文本。

**Q：`xray` 服务未启动 / 启动失败？**

- 看日志：`journalctl -u xray -n 50 --no-pager`；
- 配置文件路径：`/usr/local/etc/xray/config.json`；
  改完配置后必须 `systemctl restart xray` 才会生效；
- 端口冲突是常见原因：服务起不来时先看是不是 443 已经被别的服务占了。

**Q：`--status` 报「尚未部署」？**

- 状态文件在 `/etc/vless-reality/deploy.env`；
  如果你换过 `STATE_DIR` 环境变量，这里就对不上了；
- 单文件分发版与仓库版的状态目录相同，用哪种方式部署都能互相看到。

## 验证状态声明

这个工具的**自动化测试全部是 mock**。下面逐条列出**尚未验证**的内容，
以及已经**验证**过的内容 —— 请据此判断哪些结论可信。

### 未验证项（逐条列出）

1. **权限位 600/700 未在 Debian 真机验证** —— 开发环境是 Windows + Git Bash，
   它的 `chmod` 是**模拟**的（`stat -c '%a'` 恒为 644），所以
   「状态文件 600 / 状态目录 700 / 客户端导出目录 700 / 客户端物料文件 600」
   这些权限位断言在开发机上会**自动跳过**，只有 Debian 真机上才会真正执行。
2. **`urlencode` 的 python3 分支的覆盖范围** —— python3 是**可选依赖**，
   所以这一项分两层写清楚：
   (a) **mock 基准层**（任何机器都会执行）：一条用**独立算法**（按字节取十六进制码）
       算出来的 mock python3，与回退分支的结果**逐字节比对** ——
       两条独立路径算出同一个串才算通过，因此不依赖 python3 是否存在；
   (b) **真实分支层**（受「功能可用守卫」控制）：只有
       `python3 -c 'import sys,urllib.parse'` 成功时才拿真实 python3 的输出
       与回退分支对比；不可用时登记一条说明（**不断言失败**）。
   → 目标机若没装 python3，只有 (a) 生效；(b) 是否执行取决于目标机。
   （开发机上 python3 的可用性是**会变的** —— 本条不把任何机器的现状写成既定事实。）
3. **`detect_os` 对真实 `/etc/os-release` 未验证** —— 单元测试只用临时构造的
   os-release 文件（含 CRLF 变体），没有对真实系统文件跑过。
4. **`assert_debian` 的真机判定未验证** —— 单元测试覆盖的是构造出来的假 os-release；
   真实 Debian 上 `ID=debian` / `VERSION_ID` 的判定结果尚未实测。
5. **shellcheck 未在本机运行** —— 开发环境没有 shellcheck，
   GitHub Actions 的 shellcheck 步骤**尚未实际执行过**（仓库还没在远端跑过 CI）。
6. **单元套件含【网络依赖】断言** —— `www.microsoft.com 支持 TLS 1.3` 这条要**真连外网**；
   网络不通或被中间设备拦下时，那一条断言会红 —— 这是**已知的**环境依赖，不是代码缺陷。
7. **`nft` 的 handle 语义未实测** —— 本机没有 `nft` → 只能验证
   「代码取的是 handle 而不是行号」，无法验证真实 `nft` 的行为。
8. **真实 systemd 的启停未验证** —— `systemctl disable --now xray`
   与 `systemctl enable --now xray` 的真实行为没在装了 systemd 的机器上跑过。
9. **REALITY 握手未验证** —— 部署出来的节点没有与真实客户端握过手。
10. **完整部署流程未在 Debian 真机上端到端跑过** —— 但**内核安装这一步已经实测**：
    在一台真实的 Debian 13 (trixie) / x86_64 服务器上跑通了「直连 GitHub 失败 →
    自动回退镜像 → 下载 → SHA-256 校验 → 解压 → 安装二进制 → 建 xray 用户 →
    写 systemd unit」的完整链路（详见「已验证清单」）。
    尚未在真机上跑过的是：配置生成与 `xray run -test` 校验、systemd 单元的启停、
    防火墙放行、分享链接的客户端导入与 REALITY 握手。
11. **`ss` 的过滤语法未在真实环境验证** —— `ss -ltn "sport = :$port"` 这条过滤语法
    本机没有 `ss`、无法实测；退化分支 `netstat -ltn` 同理。

### 已知风险

> 以下是**已确知、无法在本工具内消除**的风险 —— 同样必须**逐条**点名。

12. **安装包的信任链止于官方 `.dgst`** —— 工具会用官方发布的 `.dgst` 里的 SHA-256
    校验内核压缩包，且校验文件**优先从直连 GitHub 取**；但当直连 GitHub 不可达时
    （这正是要走镜像/离线的场景），校验文件只能退回**同源**取 ——
    此时「包」与「校验文件」来自同一个镜像，校验只能发现**传输损坏**，
    发现不了**镜像被系统性投毒**。
    需要更强保证时，请用 `--local` 搭配**你自己从官方渠道另行核对过 SHA-256** 的安装包。
    （旧版「以 root 执行 GitHub `main` 分支上的脚本、**没有校验和校验**」的风险
    —— 计划里登记的 **T6-7** / **T10-7** —— 已从 **v1.1** 起**消除**：
    现在**不再下载、也不再以 root 执行任何第三方脚本**。）

### 已验证清单

- 所有 `.sh` 的 `bash -n` 语法检查通过；
- `bash test/unit.sh` 单元测试全部通过；
- 用 `TUI_KEY_TIMEOUT=2` / `TUI_DIGIT_TIMEOUT=2` 放大按键超时后，
  以 `TUI_TTY=1` + 管道喂按键模拟真终端的 TUI 渲染与交互路径；
- **真机（Debian 13 trixie / x86_64 / 只有 IPv6、无公网 IPv4）实测**：
  - 直连 `github.com` 失败（`curl: (7) Could not connect`）；
  - 新下载链**自动回退**到内置镜像并成功取到 `Xray-linux-64.zip`；
  - 官方 `.dgst` 的 **SHA-256 校验通过**；
  - 解压、安装二进制（`/usr/local/bin/xray`，Xray 26.10.21）、创建 `xray` 用户、
    写入 `/etc/systemd/system/xray.service` —— 全流程 **3 秒**完成。

### 整体验证边界

**Debian 真机端到端部署尚未在本开发环境验证** —— 开发环境是 Windows + Git Bash，
没有 Debian、没有 Docker、没有真 TTY。因此以下环节**都没有**在真实目标机上跑过：
配置生成与 `xray run -test` 校验、systemd 单元的启停、防火墙放行（ufw/iptables/nft）、
REALITY 握手、真实终端下的 TUI 交互与按键响应、`ss` 的端口过滤。
**内核安装**这一环已单独在真机上实测通过（见上）。
**已验证**的只有上面「已验证清单」里列出的那几项。

## 卸载说明

```bash
# 交互式卸载（卸载前确认）
sudo bash uninstall.sh

# 跳过确认直接卸载（用于无人值守场景）
sudo bash uninstall.sh --yes
```

卸载会做的事：

1. 停止并禁用 `xray` 服务（`systemctl disable --now xray`）；
2. **备份**服务端配置（备份失败会**中止**整个卸载 —— 配置没备份成功就不删原文件）；
3. 撤销防火墙放行规则（ufw / iptables / nft）；
4. 删除服务端配置文件与状态目录 `/etc/vless-reality/`；
5. **保留**客户端导出目录 `/root/vless-reality/`（里面是你的分享链接与客户端配置）。

也可以从管理菜单第 8 项卸载，或：

```bash
sudo bash install.sh --uninstall
```

> ⚠️ 单文件分发版（`dist/install.sh`）**不含** `uninstall.sh`，
> 那种情况下请手动清理：`systemctl disable --now xray` 与删除
> `/usr/local/etc/xray/config.json`。
>
> ⚠️ 卸载**不会**删除 Xray 内核本体 —— 内核是共享依赖，手动删除请直接
> `rm -f /usr/local/bin/xray`（并按需 `systemctl disable xray`）。

## 致谢与上游项目链接

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) —— 实际的代理内核，
  本工具只负责把它配置起来。
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install) —— 上游的官方内核安装脚本。
  本工具**从 v1.1 起不再执行它**（内核的下载、校验、解压、安装全部由本仓库自己的代码完成）；
  这里保留链接，是说明 systemd 单元与 `xray` 用户的约定沿用了上游的惯例。

本工具不包含上游任何代码，只是把「装内核 → 写配置 → 起服务 → 放行端口 →
导出客户端配置」这条链路脚本化，并在上面加了一层终端界面。

## 开源协议

本项目采用 [MIT 协议](LICENSE) 发布。

- 协议全文见仓库根目录的 [`LICENSE`](LICENSE) 文件。
- 单文件分发版 `dist/install.sh` 的头部带有 `SPDX-License-Identifier: MIT` 标识 ——
  那个文件被单独拷走时，协议线索也跟着走。
- 允许自由使用、复制、修改、合并、再发布与商业使用；唯一的硬性要求是
  在再发布的副本里保留版权声明与许可声明。
- 本仓库**不包含** Xray 内核代码 —— 内核从
  [XTLS/Xray-core](https://github.com/XTLS/Xray-core) 的 release 下载，其版权归上游所有。
