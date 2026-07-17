---
name: cdt
description: 用本 skill 运行 shell 命令,完成需要登录态的浏览器自动化任务,通过 cdt CLI。启动的浏览器是用户日常 Edge 的副本,复用其登录 cookie。
---

# cdt

`cdt` 从 shell 操控浏览器。启动的浏览器是用户日常 Edge 的副本,复用其登录 cookie,因此已登录的站点无需重新输入凭证即可访问。

## 会话:start 之后每条命令带 --session=<id>

`cdt start` 会自动生成并打印一个短 sessionId(不可自定义)。后续每条命令(`stop` / 工具)都用 `--session=<id>` 带上这个值。并发时的隔离就靠它:每个 AI 窗口持自己的 sessionId,两个 AI 永远不会开同一个浏览器。

## 自动清理

每次 `cdt start` 和 `cdt prepare` 都会先自动清理一次。当一个 session 处于以下状态时,清掉它的标记 + 残留 Edge 进程 + profile:
- **已死** —— chrome-devtools daemon 不再运行(daemon 与会话 1:1,daemon 死 = 会话死);或
- **卡住** —— daemon 活着,但 Edge 超过 90s 没起来(启动卡住了)。

一般不需要手动跑 `cdt sessions clean`。

Edge 是活 session 的心跳:**daemon 活 + Edge 在 = 正常工作 → 不动**;daemon 活但过了 90s 宽限期还没 Edge = 启动卡住 → 及时清掉,不用等重启。所以卡住的 `cdt start` 在下次 start/prepare 就被回收,不会堆积;真正在用的 session 绝不会被杀。

## AI Workflow

1. **Prepare**(首次/存疑时):`cdt prepare` — 确保 daemon 在跑 + 扩展已连接。
2. **Start**:`cdt start` — 注入登录 cookie + 启动隔离 Edge 会话;自动生成并打印 `session=<id>`(start 不要带 `--session`)。**读它**,后续用它。
3. **Inspect**:`cdt take_snapshot --session=<id>` — 拿元素 uid。
4. **Act**:`cdt click --session=<id> <uid>` / `cdt fill --session=<id> <uid> <value>` 等。
5. **Stop**:完成时 `cdt stop --session=<id>`(停会话 + 杀残留 Edge + 删 profile)。

快照示例:
```
uid=1_0 RootWebArea "Example Domain" url="https://example.com/"
  uid=1_1 heading "Example Domain" level="1"
```

## Command Usage

```sh
cdt <tool> --session=<id> [参数] [flags]
```

`--session=<id>` 被 cdt 剥离用于路由到你的浏览器;其余转发给 chrome-devtools-mcp。`--help` 可用;输出默认 Markdown,`--output-format=json` 取 JSON。

**required 参数用位置参数**(不带 flag),optional 才用 `--flag`。例如 `cdt fill --session=<id> <uid> <value>` 可以;`cdt fill --session=<id> --uid X --value Y` 会报 "Not enough non-option arguments"。

**工具命令会被拒**,除非 `<id>` 是经过 `cdt start` 启动的(否则 chrome-devtools 会起一个没有登录 cookie 的浏览器)。

**uid 失效重试**:快照 uid 在页面导航、SPA 局部 DOM 重建后失效;`click`/`fill` 报错时,重新 `take_snapshot` 再操作。

## cdt 专属命令

| 命令 | 作用 |
|---|---|
| `cdt prepare` | 确保 daemon 在跑 + 报告扩展连接状态(会先自动清理孤儿会话)|
| `cdt start` | 自动清理孤儿 + 注入登录 cookie + 加载默认扩展 + 抑制弹窗 + 启动隔离 Edge 会话(有头);自动生成并打印后续要用的 sessionId(不可自定义) |
| `cdt stop --session=<id>` | 停止会话 + 杀残留 Edge + 删 profile + 清标记 |
| `cdt sessions list` | 列出所有已启动会话(alive/orphan)+ 是否有 profile |
| `cdt sessions clean` | 清理 chrome-devtools daemon 已不在运行的那些会话的标记 + profile(daemon 与会话 1:1,daemon 死 = 会话死;绝不动活着的会话) |
| `cdt doctor` | 检测/装 chrome-devtools CLI + 探测 Edge + 探测 default profile + 报告扩展 |
| `cdt extension` | 打印扩展目录(用户去 `edge://extensions` 加载) |
| `cdt config set <k> <v>` | 设配置(executable/httpPort/wsPort/profilesDir/defaultProfile) |
| `cdt extensions list\|add\|remove <名字\|id>` | 管理默认加载扩展白名单;白名单扩展每次 `cdt start` **带配置**加载(像日常 Edge 新开窗口) |
| `cdt config get [k] \| list` | 读配置 |
| `cdt skills install/status/update/uninstall [--targets claude,codex\|all]` | 在 Claude Code / Codex 中管理本 skill(`~/.<target>/skills/cdt/`) |

## 默认扩展 & 弹窗抑制(每次 `cdt start` 自动)

你**不需要**自己装扩展或关弹窗 —— `cdt start` 都自动做了:

- **默认扩展** —— 日常 Edge 里白名单的扩展会**带配置**加载(代码 + chrome.storage 复制进隔离 profile,start 后用 `install_extension` 加载;manifest.key 保证 ID 稳定 → 读到已复制的设置),所以是已配置运行,不是裸装。白名单由用户一次性配置:`cdt extensions list` / `add <名字|id>` / `remove`。若站点因扩展缺失/多余表现异常,让用户调白名单,别在运行时装。
- **弹窗抑制** —— 翻译气泡、证书错误页、站点权限请求(通知/定位/摄像头/麦克风)、下载保存框都预置关闭,不会挡 `click`/`fill` 目标。

## Input Automation(uid 来自快照)

```bash
cdt take_snapshot --session=<id>                              # 文本快照, 拿元素 uid
cdt click --session=<id> "1_5"                                # 点击元素
cdt click --session=<id> "1_5" --dblClick true --includeSnapshot true
cdt drag --session=<id> "1_5" "1_6"                           # 拖拽
cdt fill --session=<id> "3_2" "hello"                         # 输入文本/选选项
cdt fill --session=<id> "3_2" "hello" --includeSnapshot true
cdt handle_dialog --session=<id> accept                       # 处理浏览器对话框
cdt handle_dialog --session=<id> dismiss --promptText "hi"
cdt hover --session=<id> "1_5"                                # 悬停
cdt press_key --session=<id> "Enter"                          # 按键/组合键
cdt press_key --session=<id> "Control+A" --includeSnapshot true
cdt type_text --session=<id> "hello" --submitKey "Enter"      # 向聚焦输入框键入
cdt upload_file --session=<id> "2_1" "C:\path\file.txt"       # 上传文件
```

## Navigation

```bash
cdt navigate_page --session=<id> --url "https://example.com"  # 导航当前页
cdt navigate_page --session=<id> --type "reload" --ignoreCache true
cdt navigate_page --session=<id> --type "back"
cdt new_page --session=<id> "https://example.com"             # 新建页
cdt list_pages --session=<id>                                 # 列出打开的页
cdt select_page --session=<id> 1                              # 选页(后续工具的上下文)
cdt select_page --session=<id> 1 --bringToFront true
cdt close_page --session=<id> 1                               # 按索引关页
```

## Emulation

```bash
cdt emulate --session=<id> --networkConditions "Offline"      # 模拟网络
cdt emulate --session=<id> --cpuThrottlingRate 4 --geolocation "0x0"
cdt emulate --session=<id> --colorScheme "dark" --viewport "1920x1080"
cdt emulate --session=<id> --userAgent "Mozilla/5.0..."
cdt resize_page --session=<id> 1920 1080
```

## Performance

```bash
cdt performance_start_trace --session=<id> true false         # 开始性能 trace
cdt performance_stop_trace --session=<id> --filePath "t.json" # 停 trace 并存文件
cdt performance_analyze_insight --session=<id> "1" "LCPBreakdown"
cdt take_memory_snapshot --session=<id> "./snap.heapsnapshot"
```

## Network

```bash
cdt list_network_requests --session=<id>                      # 列网络请求
cdt list_network_requests --session=<id> --resourceTypes Fetch
cdt list_network_requests --session=<id> --pageSize 50 --pageIdx 0
cdt get_network_request --session=<id> --reqid 1              # 取指定请求
cdt get_network_request --session=<id> --responseFilePath res.md
```

## Debugging & Inspection

```bash
cdt evaluate_script --session=<id> "() => document.title"     # 执行 JS
cdt evaluate_script --session=<id> "(a) => a.innerText" --args 1_4
cdt list_console_messages --session=<id>                       # 列 console 消息
cdt list_console_messages --session=<id> --types error
cdt get_console_message --session=<id> 1
cdt take_screenshot --session=<id>                             # 截图(视口)
cdt take_screenshot --session=<id> --fullPage true --format "jpeg" --quality 80
cdt take_screenshot --session=<id> --uid "1_5" --filePath "s.png"
cdt take_snapshot --session=<id> --verbose true --filePath "s.txt"
cdt lighthouse_audit --session=<id> --mode "navigation"        # Lighthouse 审计
cdt lighthouse_audit --session=<id> --mode "snapshot" --device "mobile"
```

## Extensions

```bash
cdt list_extensions --session=<id>
cdt install_extension --session=<id> "/path/to/extension"
cdt uninstall_extension --session=<id> "extension_id"
cdt reload_extension --session=<id> "extension_id"
cdt trigger_extension_action --session=<id> "extension_id"
```

## Experimental

实验工具默认禁用,需 `start` 时启用 flag。**注**:`cdt start` 默认不带实验 flag;需要时让用户手动 `chrome-devtools start ... --experimentalVision=true`(或直接用 chrome-devtools CLI)。

```bash
cdt click_at --session=<id> 100 200          # 需 --experimentalVision=true
cdt screencast_start --session=<id>          # 需 --experimentalScreencast=true + ffmpeg
cdt screencast_stop --session=<id>
```

## Troubleshooting

- 工具命令被拒(no --session specified)→ 每条命令带 `--session=<id>`(你 `cdt start` 打印的那个 id)。
- 工具命令被拒(was not started)→ 这个 sessionId 没 start 过;先 `cdt start --session=<id>`(它注入登录 cookie)。
- `cdt start` 碰到 session id 冲突 → 先判断这个会话是不是你自己起的;是你自己的才能 `cdt stop --session=<id>`,不是就再跑一次 `cdt start` 拿新的自动 id。
- `cdt start` 报"扩展未连接" → 让用户日常 Edge 刷新 CDT Bridge 扩展(popup 应显示"已连接");或 `cdt extension` 拿加载路径。
- 点击/填写无反应 → 重新 `take_snapshot`(uid 失效)。
- 页面需登录却显示登录页 → 让用户 `cdt prepare` 刷新 cookie 快照(短 session 站点)。
- `cdt doctor` 报 chrome-devtools 缺失 → 自动装;失败手动 `npm i -g chrome-devtools-mcp@latest`。
