---
name: cdt
description: Use this skill to run shell commands to automate browser tasks that need a login state, via the cdt CLI. The launched browser is a copy of the user's daily Edge, reusing its login cookies.
---

# cdt

`cdt` automates a browser from the shell. The browser is a copy of the user's daily Edge, reusing its login cookies, so logged-in sites work without re-entering credentials.

## Sessions: --session=<id> on every command after start

`cdt start` auto-generates and prints a short sessionId (you cannot customize it). Reuse that exact value on every later command (`stop` / tools) via `--session=<id>`. This is how concurrent AI windows stay isolated: each holds its own sessionId, so two AIs never drive the same browser.

## Auto-cleanup

Every `cdt start` and `cdt prepare` first runs an automatic cleanup. It removes a session's marker, leftover Edge processes, and profile when the session is:
- **dead** — its chrome-devtools daemon is no longer running (daemon:session is 1:1, so daemon dead = session dead); or
- **hung** — the daemon is alive but Edge never came up for over 90s (a stuck launch).

You normally don't need to run `cdt sessions clean` yourself.

Edge is the heartbeat of a live session: **daemon alive + Edge up = working → left alone**; daemon alive + Edge absent past the 90s grace window = stuck launch → cleaned promptly instead of waiting for a reboot. So a hung `cdt start` gets reaped on the next start/prepare, never piling up, and a genuinely working session is never killed.

## AI Workflow

1. **Prepare** (first time / when in doubt): `cdt prepare` — ensure the daemon is running + extension is connected.
2. **Start**: `cdt start` — inject login cookies + launch an isolated Edge session; it auto-generates + prints `session=<id>` (do not pass `--session` to start). **Read it** and reuse below.
3. **Inspect**: `cdt take_snapshot --session=<id>` — get an element uid.
4. **Act**: `cdt click --session=<id> <uid>` / `cdt fill --session=<id> <uid> <value>` etc.
5. **Stop**: when done, `cdt stop --session=<id>` (stop session + kill leftover Edge + delete profile).

Snapshot example:
```
uid=1_0 RootWebArea "Example Domain" url="https://example.com/"
  uid=1_1 heading "Example Domain" level="1"
```

## Command Usage

```sh
cdt <tool> --session=<id> [arguments] [flags]
```

`--session=<id>` is stripped by cdt and used to route to your browser; the rest is forwarded to chrome-devtools-mcp. `--help` works; output defaults to Markdown, use `--output-format=json` for JSON.

**Required tool args are positional** (no flag); optional args use `--flag`. For example, `cdt fill --session=<id> <uid> <value>` works; `cdt fill --session=<id> --uid X --value Y` errors with "Not enough non-option arguments".

**Tool commands are rejected** unless `<id>` was started via `cdt start` (otherwise chrome-devtools would launch a browser with no login cookies).

**uid retry**: snapshot uids become stale after page navigation or SPA DOM rebuilds; when `click`/`fill` errors, re-run `take_snapshot` then act.

## cdt-specific commands

| Command | Purpose |
|---|---|
| `cdt prepare` | Ensure the daemon is running + report extension connection status (auto-cleans orphans first) |
| `cdt start` | Auto-clean orphans + inject login cookies + load default extensions + suppress popups + launch an isolated Edge session (headed); auto-generates + prints the sessionId to reuse (not customizable) |
| `cdt stop --session=<id>` | Stop session + kill leftover Edge + delete profile + clear marker |
| `cdt sessions list` | List all started sessions (alive/orphan) + whether each has a profile |
| `cdt sessions clean` | Remove markers + profiles for sessions whose chrome-devtools daemon is no longer running (daemon:session is 1:1, so daemon dead = session dead; never touches live sessions) |
| `cdt doctor` | Check/install chrome-devtools CLI + detect Edge + detect default profile + report extension |
| `cdt extension` | Print the extension dir (load at `edge://extensions`) |
| `cdt config set <k> <v>` | Set config (executable/httpPort/wsPort/profilesDir/defaultProfile) |
| `cdt extensions list\|add\|remove <name\|id>` | Manage the default-load extension whitelist; whitelisted extensions load **with their settings** every `cdt start` (like opening a new window in daily Edge) |
| `cdt config get [k] \| list` | Read config |
| `cdt skills install/status/update/uninstall [--targets claude,codex\|all]` | Manage this skill in Claude Code / Codex (`~/.<target>/skills/cdt/`) |

## Default extensions & popup suppression (automatic on every `cdt start`)

You do **not** need to load extensions or dismiss popups yourself — `cdt start` does both automatically:

- **Default extensions** — whitelisted extensions from the user's daily Edge are loaded **with their settings** (code + chrome.storage are copied into the isolated profile, then loaded via `install_extension` after start; the `manifest.key` keeps the ID stable so each extension reads its already-copied chrome.storage) — so they're already configured and running, not freshly installed. The whitelist is configured once by the user with `cdt extensions list` / `add <name|id>` / `remove`. If a site misbehaves because an extension is missing or extra, ask the user to adjust the whitelist rather than installing at runtime.
- **Popups suppressed** — translate bubble, certificate-error page, site permission prompts (notifications/location/camera/mic), and the download save dialog are pre-disabled so they don't block `click`/`fill` targets.

## Input Automation (uid from snapshot)

```bash
cdt take_snapshot --session=<id>                              # text snapshot, get element uids
cdt click --session=<id> "1_5"                                # click an element
cdt click --session=<id> "1_5" --dblClick true --includeSnapshot true
cdt drag --session=<id> "1_5" "1_6"                           # drag
cdt fill --session=<id> "3_2" "hello"                         # type text / select option
cdt fill --session=<id> "3_2" "hello" --includeSnapshot true
cdt handle_dialog --session=<id> accept                       # handle a browser dialog
cdt handle_dialog --session=<id> dismiss --promptText "hi"
cdt hover --session=<id> "1_5"                                # hover
cdt press_key --session=<id> "Enter"                          # key / key combo
cdt press_key --session=<id> "Control+A" --includeSnapshot true
cdt type_text --session=<id> "hello" --submitKey "Enter"      # type into focused input
cdt upload_file --session=<id> "2_1" "C:\path\file.txt"       # upload a file
```

## Navigation

```bash
cdt navigate_page --session=<id> --url "https://example.com"  # navigate current page
cdt navigate_page --session=<id> --type "reload" --ignoreCache true
cdt navigate_page --session=<id> --type "back"
cdt new_page --session=<id> "https://example.com"             # new page
cdt list_pages --session=<id>                                 # list open pages
cdt select_page --session=<id> 1                              # select page (context for future tools)
cdt select_page --session=<id> 1 --bringToFront true
cdt close_page --session=<id> 1                               # close page by index
```

## Emulation

```bash
cdt emulate --session=<id> --networkConditions "Offline"      # emulate network
cdt emulate --session=<id> --cpuThrottlingRate 4 --geolocation "0x0"
cdt emulate --session=<id> --colorScheme "dark" --viewport "1920x1080"
cdt emulate --session=<id> --userAgent "Mozilla/5.0..."
cdt resize_page --session=<id> 1920 1080
```

## Performance

```bash
cdt performance_start_trace --session=<id> true false         # start perf trace
cdt performance_stop_trace --session=<id> --filePath "t.json" # stop trace, save to file
cdt performance_analyze_insight --session=<id> "1" "LCPBreakdown"
cdt take_memory_snapshot --session=<id> "./snap.heapsnapshot"
```

## Network

```bash
cdt list_network_requests --session=<id>                      # list network requests
cdt list_network_requests --session=<id> --resourceTypes Fetch
cdt list_network_requests --session=<id> --pageSize 50 --pageIdx 0
cdt get_network_request --session=<id> --reqid 1              # get a specific request
cdt get_network_request --session=<id> --responseFilePath res.md
```

## Debugging & Inspection

```bash
cdt evaluate_script --session=<id> "() => document.title"     # run JS
cdt evaluate_script --session=<id> "(a) => a.innerText" --args 1_4
cdt list_console_messages --session=<id>                       # list console messages
cdt list_console_messages --session=<id> --types error
cdt get_console_message --session=<id> 1
cdt take_screenshot --session=<id>                             # screenshot (viewport)
cdt take_screenshot --session=<id> --fullPage true --format "jpeg" --quality 80
cdt take_screenshot --session=<id> --uid "1_5" --filePath "s.png"
cdt take_snapshot --session=<id> --verbose true --filePath "s.txt"
cdt lighthouse_audit --session=<id> --mode "navigation"        # Lighthouse audit
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

Experimental tools are disabled by default and need flags at `start`. **Note**: `cdt start` does not pass experimental flags by default; if needed, have the user run `chrome-devtools start ... --experimentalVision=true` manually.

```bash
cdt click_at --session=<id> 100 200          # requires --experimentalVision=true
cdt screencast_start --session=<id>          # requires --experimentalScreencast=true + ffmpeg
cdt screencast_stop --session=<id>
```

## Troubleshooting

- a tool command is rejected with "no --session specified" → pass `--session=<id>` on every command (the id printed by your `cdt start`).
- a tool command is rejected with "was not started" → that sessionId was never started here; run `cdt start --session=<id>` first (it injects the login cookies).
- a session id collision on `cdt start` → first decide whether you started that session yourself; only `cdt stop --session=<id>` it if you did, otherwise just run `cdt start` again for a fresh auto id.
- `cdt start` reports "extension not connected" → have the user refresh the CDT Bridge extension in daily Edge (popup should show "connected"); or run `cdt extension` for the load path.
- click/fill has no effect → re-run `take_snapshot` (uid stale).
- page needs login but shows the login page → have the user run `cdt prepare` to refresh the cookie snapshot (short-session sites).
- `cdt doctor` reports chrome-devtools missing → auto-installed; on failure run `npm i -g chrome-devtools-mcp@latest` manually.
