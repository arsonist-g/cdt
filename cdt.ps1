# cdt.ps1 - Chrome DevTools MCP wrapper (v4, explicit sessionId)
# Orchestrates: bridge daemon (cookie/inject) + chrome-devtools (isolated browser per session)
#
# Sessions are identified by an EXPLICIT --session=<id>, passed on every start/stop/tool command.
# cdt does NOT use a shared "current session" file — that would let concurrent AI windows steal
# each other's browser. Each AI gets a sessionId from `cdt start` and reuses it on later commands.
#
# Commands:
#   cdt start [--session=<id>]              Inject cookies + start chrome-devtools (isolated profile, headed).
#                                           Prints the sessionId to reuse on subsequent commands.
#   cdt <tool> --session=<id> [args...]     Forward to chrome-devtools (rejected if <id> was not started).
#   cdt stop --session=<id>                 Stop chrome-devtools + kill leftover Edge + delete profile.
#   cdt config set <k> <v> | get [k] | list Read/set config (executable/httpPort/wsPort/profilesDir)
#   cdt doctor                              Install chrome-devtools CLI + detect Edge + check extension
#   cdt extension                           Print extension dir (load at edge://extensions)
#   cdt skills install|status|update|uninstall [--targets claude,codex|all]
#
# Config: ~/.cdt/config.json — read on every run, injected into $env:CDT_* for THIS process only.
# Session markers: ~/.cdt/sessions/<id>.started — written by start, checked by tool commands, removed by stop.
#
# NOTE: $ErrorActionPreference='Continue' so chrome-devtools (npm .ps1 shim -> node) stderr does not
# abort the script (PS 5.1 wraps native stderr as NativeCommandError). HTTP calls use -ErrorAction Stop.

$ErrorActionPreference = "Continue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$BridgeDir = Join-Path $Root "bridge"
$DaemonScript = Join-Path $BridgeDir "daemon.mjs"

# User data lives OUTSIDE the npm package (package is read-only / replaced on upgrade)
$DataDir = Join-Path $env:USERPROFILE ".cdt"
$ConfigFile = Join-Path $DataDir "config.json"

function Read-Config {
  if (-not (Test-Path $ConfigFile)) { return $null }
  try { return Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch { return $null }
}

function Apply-Config {
  $cfg = Read-Config
  if (-not $cfg) { return }
  if ($cfg.executable   -and -not $env:CDT_EXECUTABLE)   { $env:CDT_EXECUTABLE   = [string]$cfg.executable }
  if ($cfg.httpPort     -and -not $env:CDT_HTTP_PORT)    { $env:CDT_HTTP_PORT    = [string]$cfg.httpPort }
  if ($cfg.wsPort       -and -not $env:CDT_WS_PORT)      { $env:CDT_WS_PORT      = [string]$cfg.wsPort }
  if ($cfg.profilesDir  -and -not $env:CDT_PROFILES_DIR) { $env:CDT_PROFILES_DIR = [string]$cfg.profilesDir }
}

Apply-Config

$HttpPort = if ($env:CDT_HTTP_PORT) { $env:CDT_HTTP_PORT } else { "17891" }
$HttpBase = "http://127.0.0.1:$HttpPort"
$ProfilesDir = if ($env:CDT_PROFILES_DIR) { $env:CDT_PROFILES_DIR } else { Join-Path $DataDir ".profiles" }
$SessionsDir = Join-Path $DataDir "sessions"
$Executable = $env:CDT_EXECUTABLE

# daemon 活但 Edge 没起来超过此秒数 → 判定卡住,清理。launching 窗口兜底(正常 Edge 远快于此起来)。
$HungThresholdSeconds = 90

# Extract and strip --session=<id> (cdt-level session id; not forwarded to chrome-devtools).
# Each concurrent AI uses its own sessionId, so we never rely on a shared "current session" file.
$SessionId = $null
if ($args.Count -gt 0) {
  $_clean = New-Object System.Collections.Generic.List[string]
  foreach ($a in $args) {
    $s = [string]$a
    if ($s -like "--session=*") { $SessionId = $s.Substring("--session=".Length) }
    else { $_clean.Add($s) }
  }
  $args = $_clean.ToArray()
}

function Write-Step($m) { Write-Host "[cdt] $m" -ForegroundColor Cyan }

function New-ProfilesDir {
  if (-not (Test-Path $ProfilesDir)) { New-Item -ItemType Directory -Path $ProfilesDir -Force | Out-Null }
}

function Start-DaemonIfNotRunning {
  try { Invoke-RestMethod "$HttpBase/status" -TimeoutSec 2 -ErrorAction Stop | Out-Null; return $true }
  catch {}
  Write-Step "bridge daemon not running, starting in background..."
  New-ProfilesDir
  $p = Start-Process -FilePath "node" -ArgumentList "`"$DaemonScript`"" -WorkingDirectory $BridgeDir -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 300
    try { Invoke-RestMethod "$HttpBase/status" -TimeoutSec 1 -ErrorAction Stop | Out-Null; return $true } catch {}
  }
  throw "bridge daemon failed to start (node PID=$($p.Id))"
}

function Wait-ExtensionConnected([int]$TimeoutSec = 35) {
  # 扩展靠 chrome.alarms(MV3 最小周期 30s)重连: daemon 冷启后立刻读 extConnected 会落进重连窗口, 误报断连。
  # 宽限轮询覆盖该周期; 已连则首次即返回(零等待); daemon 其间挂掉则提前返回 false。
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $s = Invoke-RestMethod "$HttpBase/status" -TimeoutSec 2 -ErrorAction Stop
      if ($s.extConnected) { return $true }
    } catch { return $false }
    Start-Sleep -Milliseconds 2000
  }
  return $false
}

function Test-SessionStarted([string]$id) { return (Test-Path (Join-Path $SessionsDir "$id.started")) }

function Unmark-Session([string]$id) {
  $m = Join-Path $SessionsDir "$id.started"
  if (Test-Path $m) { Remove-Item $m -Force }
}

function New-SessionId {
  # 短随机 id: s + 5 位 base36 (共 6 字符),token 友好。
  $c = "0123456789abcdefghijklmnopqrstuvwxyz"
  $id = "s"
  for ($i = 0; $i -lt 5; $i++) { $id += $c[(Get-Random -Maximum 36)] }
  return $id
}

function Try-ClaimSession([string]$id) {
  # 原子占位:CreateNew 打开标记文件,已存在则抛异常(OS 级原子)。并发 start 即使生成相同随机 id,
  # 也只有一个能 claim 成功 → 消除竞态,自动 id 永不撞已存在的会话。
  if (-not (Test-Path $SessionsDir)) { New-Item -ItemType Directory -Path $SessionsDir -Force | Out-Null }
  try {
    $fs = [System.IO.File]::Open((Join-Path $SessionsDir "$id.started"), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $fs.Close()
    return $true
  } catch { return $false }
}

function Test-DaemonAlive([string]$id) {
  # 复刻 chrome-devtools 的 isDaemonRunning: 读 daemon pid 文件 + 进程存活检测。
  # daemon 和 session 1:1;daemon 活 = session 活(start 返回时 daemon 已 ready,不受 Edge launching 时机影响;
  # daemon 崩了进程即消失,不会像 Edge 僵尸进程那样误判)。Windows pid 文件: $env:TEMP\chrome-devtools-mcp-<id>\daemon.pid。
  $pidFile = Join-Path $env:TEMP "chrome-devtools-mcp-$id\daemon.pid"
  if (-not (Test-Path $pidFile)) { return $false }
  $raw = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue)
  if (-not $raw) { return $false }
  $dpid = $raw.Trim()
  if ($dpid -notmatch '^\d+$') { return $false }
  return ($null -ne (Get-Process -Id ([int]$dpid) -ErrorAction SilentlyContinue))
}

function Get-EdgeProcesses([string]$id) {
  # 属于本 session 的 Edge 进程(CommandLine 的 profile 路径含 cdt-<id>)
  return @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -OperationTimeoutSec 30 -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -and ($_.CommandLine -like "*cdt-$id*") })
}

function Stop-ProcessTree([int]$procId) {
  # 杀进程树(主 + 子孙)。单 Stop-Process 只杀主 pid,chrome-devtools daemon 的 node 子孙会残留。
  if ($procId -le 0) { return }
  try { & taskkill /PID $procId /T /F 2>$null | Out-Null } catch {}
  if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
    try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Invoke-SessionClean {
  # 清两类该清的 session:
  #  (1) 死 daemon(Test-DaemonAlive=false):删标记 + 杀残留 Edge + 删 profile。
  #  (2) 卡住 daemon(daemon 活但 Edge 没起来超过 $HungThresholdSeconds):杀进程树 + 删标记 + 删 profile。
  # 正常(daemon 活 + Edge 在)和 launching 中(daemon 活 + Edge 不在 + 新)绝不动 —— 正常启动永不被误清。
  if (-not (Test-Path $SessionsDir)) { return 0 }
  $ms = @(Get-ChildItem $SessionsDir -Filter "*.started" -ErrorAction SilentlyContinue)
  if ($ms.Count -eq 0) { return 0 }
  $removed = 0
  foreach ($m in $ms) {
    $id = $m.BaseName
    $profile = Join-Path $ProfilesDir "cdt-$id"
    if (-not (Test-DaemonAlive $id)) {
      # (1) 死 daemon
      Remove-Item $m.FullName -Force
      foreach ($h in (Get-EdgeProcesses $id)) { try { Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
      if (Test-Path $profile) { Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue }
      Write-Step "cleaned orphan: $id"
      $removed++
      continue
    }
    # daemon 活:看 Edge 是否起来(正常 session 必有 Edge)
    if ((Get-EdgeProcesses $id).Count -gt 0) { continue }
    $pidFile = Join-Path $env:TEMP "chrome-devtools-mcp-$id\daemon.pid"
    $age = -1
    if (Test-Path $pidFile) { $age = ((Get-Date) - (Get-Item $pidFile).LastWriteTime).TotalSeconds }
    if ($age -ge 0 -and $age -lt $HungThresholdSeconds) { continue }  # launching 中,保留
    # (2) 卡住:daemon 活 + Edge 不在 + 超过阈值
    $dpid = 0
    if (Test-Path $pidFile) { try { $dpid = [int]((Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()) } catch {} }
    Write-Step "cleaning hung session: $id (daemon alive, no Edge for $([int]$age)s)"
    if ($dpid -gt 0) { Stop-ProcessTree $dpid }
    Remove-Item $m.FullName -Force
    if (Test-Path $profile) { Remove-Item $profile -Recurse -Force -ErrorAction SilentlyContinue }
    $removed++
  }
  return $removed
}

# --- 默认扩展加载: 从日常 profile 复制扩展状态(代码+存储+注册)到隔离 profile ---
# 与 cookie 正交: cookie 走明文注入(ABE), 扩展状态无 ABE 可直接复制。
# 复制后扩展是"已安装已配置"状态(非首启、带 chrome.storage 设置), 就像日常 profile 新开窗口。
# 关键依据(已验证): extensions.settings 在 Secure Preferences 且无 per-entry MAC; path 是相对路径;
#   manifest 含 key → unpacked 加载后 ID 稳定。

function Get-DefaultProfile {
  # 日常主 profile 路径: config.defaultProfile 优先, 否则探测默认 Edge 路径。都不在返回 $null(降级)。
  $cfg = Read-Config
  if ($cfg -and $cfg.defaultProfile) { return [string]$cfg.defaultProfile }
  $default = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
  if (Test-Path $default) { return $default }
  return $null
}

function Get-ExtensionLatestDir([string]$extId) {
  # 返回 <defaultProfile>\Default\Extensions\<id>\ 下版本号最大的目录(去 _0 后缀)。找不到 $null。
  $ep = Get-DefaultProfile
  if (-not $ep) { return $null }
  $base = Join-Path $ep "Default\Extensions\$extId"
  if (-not (Test-Path $base)) { return $null }
  $latest = $null; $latestVer = $null
  foreach ($d in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
    $verStr = $d.Name -replace '_\d+$',''
    try { $v = [version]$verStr } catch { continue }
    if (-not $latestVer -or $v -gt $latestVer) { $latestVer = $v; $latest = $d.FullName }
  }
  return $latest
}

function Resolve-ExtensionName([string]$versionDir) {
  # manifest.name 若是 __MSG_x__ 占位符, 走 _locales\<default_locale>\messages.json 解析。失败返回 $null。
  $manifestPath = Join-Path $versionDir "manifest.json"
  if (-not (Test-Path $manifestPath)) { return $null }
  try { $m = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
  $name = [string]$m.name
  if ($name -notmatch '^__MSG_(.+)__$') { return $name }
  $key = $matches[1]
  $locale = [string]$m.default_locale
  if (-not $locale) { return $null }
  $msgPath = Join-Path $versionDir "_locales\$locale\messages.json"
  if (-not (Test-Path $msgPath)) { return $null }
  try {
    $msg = Get-Content $msgPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $entry = $msg.$key
    if ($entry -and $entry.message) { return [string]$entry.message }
  } catch {}
  return $null
}

function Get-InstalledExtensions {
  # 扫描日常 profile 全部扩展, 返回 @{Id;Version;Name;Dir} 列表。defaultProfile 缺返回 @()。
  $ep = Get-DefaultProfile
  if (-not $ep) { return @() }
  $extRoot = Join-Path $ep "Default\Extensions"
  if (-not (Test-Path $extRoot)) { return @() }
  $out = @()
  foreach ($idDir in (Get-ChildItem $extRoot -Directory -ErrorAction SilentlyContinue)) {
    $id = $idDir.Name
    $verDir = Get-ExtensionLatestDir $id
    if (-not $verDir) { continue }
    $ver = Split-Path $verDir -Leaf
    $name = Resolve-ExtensionName $verDir
    if (-not $name) { $name = $id }
    $out += [PSCustomObject]@{ Id = $id; Version = $ver; Name = $name; Dir = $verDir }
  }
  return $out
}

function Find-ExtensionIdByName([string]$query) {
  # 名字包含匹配(不区分大小写), 返回候选 @{Id;Name} 列表。query 空返回 @()。
  $q = $query.Trim()
  if (-not $q) { return @() }
  $out = @()
  foreach ($e in (Get-InstalledExtensions)) {
    if ($e.Name -and $e.Name.ToLower().Contains($q.ToLower())) {
      $out += [PSCustomObject]@{ Id = $e.Id; Name = $e.Name }
    }
  }
  return $out
}

function Get-WhitelistIds {
  # 读 config.extensions, 归一化成数组(兼容 null/string/数组)。空返回 @()。
  $cfg = Read-Config
  if (-not $cfg -or -not $cfg.PSObject.Properties['extensions']) { return @() }
  $v = $cfg.extensions
  if ($v -is [string]) { return @($v) }
  return @(@($v) | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

function Set-WhitelistIds([string[]]$ids) {
  # 写回 config.extensions(小写去重保序, 空则移除字段)。其他字段保留。
  if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
  $cfg = Read-Config
  if (-not $cfg) { $cfg = [PSCustomObject]@{} }
  $clean = @($ids | ForEach-Object { ([string]$_).ToLower().Trim() } | Where-Object { $_ } | Select-Object -Unique)
  if ($clean.Count -eq 0) {
    if ($cfg.PSObject.Properties['extensions']) { $cfg.PSObject.Properties.Remove('extensions') }
  } else {
    $cfg | Add-Member -NotePropertyName 'extensions' -NotePropertyValue $clean -Force
  }
  ($cfg | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding utf8
}

function Resolve-ExtensionArgument([string]$arg) {
  # 把用户传入(名字或 ID)解析为单个 ID。ID 形(^[a-p]{32}$)直用; 否则名字匹配。
  # 0 命中报错; 1 命中返回; 多命中打印候选表。返回 $null 表示未解析。
  if (-not $arg) { return $null }
  if ($arg -match '^[a-p]{32}$') { return $arg.ToLower() }
  $cands = @(Find-ExtensionIdByName $arg)
  if ($cands.Count -eq 0) {
    Write-Step "no installed extension matches '$arg' (run: cdt extensions list)"
    return $null
  }
  if ($cands.Count -eq 1) { return $cands[0].Id }
  Write-Step "multiple extensions match '$arg', be more specific or use the ID:"
  foreach ($c in $cands) { Write-Host ("  {0,-34} {1}" -f $c.Id, $c.Name) }
  return $null
}

function Copy-ExtensionToProfile([string]$extId, [string]$destProfile) {
  # 复制单个扩展的代码 + chrome.storage 到隔离 profile, 返回代码目录路径($null=失败)。
  # 代码由 start 后的 install_extension 工具加载(unpacked); chrome.storage 按 ID 索引, manifest.key 保证 ID 稳定 → 设置对应。
  # 不写 Secure Preferences: Edge 用 profile 私钥对 extensions.settings.<id> 受保护字段做 MAC,
  # 外部注入条目 MAC 无效 → 启动即丢弃 + 删 Extensions 目录(实测)。load-extension 绕过该校验。
  $srcDir = Get-ExtensionLatestDir $extId
  if (-not $srcDir) { Write-Step "extension $extId not in default profile, skipped"; return $null }
  $ep = Get-DefaultProfile
  # 1. 代码: Extensions\<id>\<ver>
  $ver = Split-Path $srcDir -Leaf
  $destCode = Join-Path $destProfile "Default\Extensions\$extId\$ver"
  if (-not (Test-Path $destCode)) {
    New-Item -ItemType Directory -Path (Split-Path $destCode -Parent) -Force | Out-Null
    Copy-Item -Path $srcDir -Destination $destCode -Recurse -Force -ErrorAction SilentlyContinue
  }
  if (-not (Test-Path $destCode)) { Write-Step "copy failed for $extId"; return $null }
  # 2. chrome.storage.local / sync(ID 稳定 → 复用日常 profile 的设置)
  foreach ($store in @("Local Extension Settings","Sync Extension Settings")) {
    $srcStore = Join-Path $ep "Default\$store\$extId"
    if (Test-Path $srcStore) {
      $destStore = Join-Path $destProfile "Default\$store\$extId"
      if (-not (Test-Path $destStore)) {
        New-Item -ItemType Directory -Path (Split-Path $destStore -Parent) -Force | Out-Null
        Copy-Item -Path $srcStore -Destination $destStore -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
  }
  return $destCode
}

function Set-SessionPreferences([string]$destProfile) {
  # 写隔离 profile 的 Default\Preferences 抑制翻译/下载框/权限请求。读-合并-无BOM写回。
  $prefsFile = Join-Path $destProfile "Default\Preferences"
  $prefs = $null
  if (Test-Path $prefsFile) {
    try { $raw = Get-Content $prefsFile -Raw -Encoding UTF8 -ErrorAction Stop; if ($raw -and $raw.Trim()) { $prefs = $raw | ConvertFrom-Json -ErrorAction Stop } }
    catch { Write-Step "Preferences parse failed, skip suppress prefs (chromeArg still applies): $($_.Exception.Message)"; return }
  }
  if (-not $prefs) { $prefs = [PSCustomObject]@{} }

  # translate.enabled = false(保险2; 保险1 是 chromeArg --disable-features=Translate)
  if (-not $prefs.PSObject.Properties['translate']) { $prefs | Add-Member translate ([PSCustomObject]@{enabled=$false}) -Force }
  elseif (-not $prefs.translate.PSObject.Properties['enabled']) { $prefs.translate | Add-Member enabled $false -Force }
  else { $prefs.translate.enabled = $false }

  # download.prompt_for_download = false(下载不弹保存框)
  if (-not $prefs.PSObject.Properties['download']) { $prefs | Add-Member download ([PSCustomObject]@{prompt_for_download=$false}) -Force }
  elseif (-not $prefs.download.PSObject.Properties['prompt_for_download']) { $prefs.download | Add-Member prompt_for_download $false -Force }
  else { $prefs.download.prompt_for_download = $false }

  # profile.default_content_setting_values: 通知/定位/摄像头/麦克风 block(2)
  $dcs = [PSCustomObject]@{ notifications=2; geolocation=2; media_stream_camera=2; media_stream_mic=2 }
  if (-not $prefs.PSObject.Properties['profile']) { $prefs | Add-Member profile ([PSCustomObject]@{default_content_setting_values=$dcs}) -Force }
  elseif (-not $prefs.profile.PSObject.Properties['default_content_setting_values']) { $prefs.profile | Add-Member default_content_setting_values $dcs -Force }
  else { foreach ($p in $dcs.PSObject.Properties) { $prefs.profile.default_content_setting_values | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force } }

  $json = $prefs | ConvertTo-Json -Depth 100
  [System.IO.File]::WriteAllText($prefsFile, $json, (New-Object System.Text.UTF8Encoding $false))
}

# --- cdt skill 安装到 AI 工具(仿 smart-search skills: ~/.<target>/skills/cdt/) ---
$SkillName = "cdt"
$TargetMap = [ordered]@{ "claude" = "Claude Code"; "codex" = "Codex" }

function Install-SkillTo([string]$target) {
  $label = $TargetMap[$target]
  if (-not $label) { Write-Step "unknown target: $target (valid: $($TargetMap.Keys -join ', '))"; return }
  $dest = Join-Path $env:USERPROFILE ".$target\skills\$SkillName"
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  Copy-Item (Join-Path $Root "SKILL.md") $dest -Force
  $n = @(Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue).Count
  Write-Step "installed cdt skill -> ${label}: $dest ($n files)"
}

function Get-SkillStatus([string]$target) {
  $label = $TargetMap[$target]
  if (-not $label) { Write-Step "unknown target: $target"; return }
  $dest = Join-Path $env:USERPROFILE ".$target\skills\$SkillName"
  $bundled = Join-Path $Root "SKILL.md"
  if (Test-Path (Join-Path $dest "SKILL.md")) {
    $n = @(Get-ChildItem $dest -Recurse -File -ErrorAction SilentlyContinue).Count
    $state = "stale"
    if (Test-Path $bundled) {
      $bh = (Get-FileHash $bundled -Algorithm SHA256).Hash
      $ih = (Get-FileHash (Join-Path $dest "SKILL.md") -Algorithm SHA256).Hash
      if ($bh -eq $ih) { $state = "up_to_date" }
    }
    Write-Step "${label}: $state ($n files) -> $dest"
  } else {
    Write-Step "${label}: NOT installed -> $dest"
  }
}

function Uninstall-SkillFrom([string]$target) {
  $label = $TargetMap[$target]
  if (-not $label) { Write-Step "unknown target: $target"; return }
  $dest = Join-Path $env:USERPROFILE ".$target\skills\$SkillName"
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Write-Step "removed cdt skill from ${label}: $dest" }
  else { Write-Step "${label}: nothing to remove ($dest)" }
}

if ($args.Count -eq 0) {
  Write-Host "Usage: cdt start [--session=<id>] | stop --session=<id> | <tool> --session=<id> [args] | config ... | doctor | extension | skills ..."
  exit 1
}

$cmd = [string]$args[0]

switch ($cmd) {
  "start" {
    $cleaned = Invoke-SessionClean
    if ($cleaned -gt 0) { Write-Step "auto-cleaned $cleaned orphan session(s)" }
    Start-DaemonIfNotRunning | Out-Null
    # daemon 冷启后扩展还在 30s alarm 重连窗口里; 不等的话紧接的 inject 会因 extConnected=false 误失败。
    try { $extOk = (Invoke-RestMethod "$HttpBase/status" -TimeoutSec 2 -ErrorAction Stop).extConnected } catch { $extOk = $false }
    if (-not $extOk) {
      Write-Step "waiting for CDT Bridge extension to reconnect..."
      $extOk = Wait-ExtensionConnected 35
    }
    if (-not $extOk) {
      Write-Step "extension NOT connected - run 'cdt extension' for the load path, then retry (cdt start)."
      exit 1
    }
    if ($SessionId) { Write-Step "start ignores --session=<id>; the session id is auto-generated and cannot be customized." }
    # 原子占位:CreateNew 保证并发 start 不会拿到同一个 id(消除竞态)。do/until 直到占到一个空 id。
    do { $sessionId = New-SessionId } until (Try-ClaimSession $sessionId)
    New-ProfilesDir
    $profile = Join-Path $ProfilesDir "cdt-$sessionId"
    if (Test-Path $profile) { Remove-Item $profile -Recurse -Force }
    try {
      # 1. inject cookies into the isolated profile (headed, known to persist)
      $body = @{ userDataDir = $profile; executablePath = $Executable; headless = $false } | ConvertTo-Json -Compress
      Write-Step "Injecting cookies into $profile ..."
      $inj = Invoke-RestMethod -Method POST -Uri "$HttpBase/inject" -Body $body -ContentType "application/json" -TimeoutSec 120 -ErrorAction Stop
      Write-Step "Injected $($inj.injected) cookies"

      # 2. clear Singleton lock left by puppeteer so chrome-devtools can launch same profile
      Get-ChildItem $profile -Filter "Singleton*" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

      # 3. 默认扩展: 复制白名单扩展(代码+chrome.storage)到隔离 profile, 由步骤6 install_extension 加载
      $loadDirs = @()
      $wl = Get-WhitelistIds
      if ($wl.Count -gt 0 -and (Get-DefaultProfile)) {
        foreach ($id in $wl) { $d = Copy-ExtensionToProfile $id $profile; if ($d) { $loadDirs += $d } }
        if ($loadDirs.Count -gt 0) { Write-Step "Prepared $($loadDirs.Count) extension(s) for install" }
      }

      # 4. 弹窗抑制 Preferences(翻译/下载框/权限请求)
      Set-SessionPreferences $profile

      # 5. start chrome-devtools (launch mode, headed, per-sessionId daemon)
      # chromeArg 透传在 daemon 模式失效: serializeArgs 把 array 项展开成 "--chrome-arg <item>" 空格形式,
      # 当 item 本身以 "--" 开头(如 --load-extension)时 daemon 层 yargs(strict)把它当未知选项丢弃(实测)。
      # 故改用原生选项: --allow-unrestricted-paths 放开 install_extension 的 workspace roots 路径校验;
      # --acceptInsecureCerts 替代 --ignore-certificate-errors。翻译/下载/权限靠步骤4的 Preferences。
      $cdtArgs = @("start", "--userDataDir=$profile", "--sessionId=$sessionId", "--headless=false", "--allow-unrestricted-paths", "--acceptInsecureCerts")
      if ($Executable) { $cdtArgs += "--executablePath=$Executable" }
      Write-Step "chrome-devtools start (session=$sessionId)..."
      # chrome-devtools 输出重定向到日志文件(诊断 + 避免 disclaimer 刷终端)。
      # 注意: stdio 继承的切断由 bin/cdt.mjs(powershell 用 pipe 而非 inherit)统一处理 —— PS 层的 1>file 不改变
      # native 的 OS stdout handle, 单靠它解决不了 `cdt start | head` 卡死。保留 "& chrome-devtools" 直接调用
      # (已知可靠); 不用 Start-Process 是因为 PS5.1 它 + 重定向 + WaitForExit 易死锁, 且系统 PATHEXT 不含 .ps1
      # 会命中无扩展名 bash shim。超时见 inject 的 -TimeoutSec。
      $logDir = Join-Path $DataDir ".logs"
      if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
      $outLog = Join-Path $logDir "start-${sessionId}.out.log"
      $errLog = Join-Path $logDir "start-${sessionId}.err.log"
      & chrome-devtools @cdtArgs 1>$outLog 2>$errLog
      if ($LASTEXITCODE -ne 0) { throw "chrome-devtools start failed exit=$LASTEXITCODE (log: $errLog)" }
    } catch {
      Unmark-Session $sessionId   # inject/launch 失败,释放占位,避免残留孤儿标记
      # Invoke-RestMethod 在 503 时抛的异常 message 只是 "(503) 服务器不可用", 吞掉了 daemon 返回的真实原因。
      # 从异常 Response 的 body 里取 daemon 的 JSON error, 让失败可操作(而非一句不可操作的 503)。
      $detail = $null
      if ($_.Exception -and $_.Exception.Response) {
        try {
          $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
          $rb = $reader.ReadToEnd(); $reader.Close()
          $j = $rb | ConvertFrom-Json -ErrorAction SilentlyContinue
          if ($j -and $j.error) { $detail = [string]$j.error } elseif ($rb) { $detail = $rb }
        } catch {}
      }
      Write-Step "start failed, session claim released: $sessionId."
      Write-Step "  Reason: $(if ($detail) { $detail } else { $_.Exception.Message })"
      Write-Step "  Hint: doctor 只查 /status(daemon活+扩展连+缓存cookie), 不验证 puppeteer 能否起 Edge;"
      Write-Step "        run 'cdt doctor' 做 inject 预检。常见: 扩展断连/Edge 路径错/profile 锁残留。重试: cdt start"
      exit 1
    }
    # 6. install_extension 加载白名单扩展(chrome-devtools start 已返回=daemon ready; 路径校验已放开)。
    # CDP 加载 unpacked 代码目录, manifest.key 保证 ID=商店ID → 读已复制的 chrome.storage → 带配置。
    if ($loadDirs.Count -gt 0) {
      $installed = 0
      foreach ($d in $loadDirs) {
        $r = cdt install_extension --session=$sessionId $d 2>$null | Out-String
        if ($r -notmatch '"isError"\s*:\s*true' -and $r -notmatch '(?m)Error:') { $installed++ }
        else { Write-Step "install_extension failed: $(Split-Path (Split-Path $d -Parent) -Leaf)" }
      }
      Write-Step "Installed $installed/$($loadDirs.Count) extension(s)"
    }
    Write-Step "Ready: session=$sessionId"
    Write-Step "Pass --session=$sessionId on EVERY subsequent cdt command (stop, navigate_page, take_snapshot, ...)."
  }

  "stop" {
    if (-not $SessionId) {
      Write-Step "no --session specified. Pass the sessionId from your 'cdt start':"
      Write-Host "    cdt stop --session=<id>"
      exit 1
    }
    $sessionId = $SessionId
    $profile = Join-Path $ProfilesDir "cdt-$sessionId"
    Write-Step "Stopping chrome-devtools (session=$sessionId)..."
    & chrome-devtools stop --sessionId=$sessionId 2>$null

    # kill Edge processes still holding the profile
    $holds = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -OperationTimeoutSec 30 -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -and ($_.CommandLine -like "*cdt-$sessionId*") })
    foreach ($h in $holds) {
      Write-Step "kill leftover Edge PID=$($h.ProcessId)"
      try { Stop-Process -Id $h.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
    if (Test-Path $profile) { Remove-Item $profile -Recurse -Force; Write-Step "Deleted profile" }
    Unmark-Session $sessionId
    Write-Step "Stopped session=$sessionId"
  }

  "config" {
    $sub = if ($args.Count -gt 1) { [string]$args[1] } else { "" }
    $validKeys = @("executable", "httpPort", "wsPort", "profilesDir", "defaultProfile")
    switch ($sub) {
      "set" {
        if ($args.Count -lt 4) {
          Write-Host "Usage: cdt config set <key> <value>"
          Write-Host "Keys: $($validKeys -join ', ')"
          exit 1
        }
        $key = [string]$args[2]; $val = [string]$args[3]
        if ($validKeys -notcontains $key) {
          Write-Host "Unknown key: $key"
          Write-Host "Keys: $($validKeys -join ', ')"
          exit 1
        }
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        $cfg = Read-Config
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
        $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $val -Force
        $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding utf8
        Write-Step "config set $key = $val"
        Write-Step "(-> $ConfigFile)"
      }
      "get" {
        $cfg = Read-Config
        if (-not $cfg) { Write-Host "(no config at $ConfigFile)"; exit 0 }
        if ($args.Count -ge 3) { $key = [string]$args[2]; Write-Host "$key = $($cfg.$key)" }
        else { $cfg | Format-List }
      }
      "list" {
        $cfg = Read-Config
        if (-not $cfg) { Write-Host "(no config at $ConfigFile)"; exit 0 }
        $cfg | Format-List
      }
      default {
        Write-Host "Usage: cdt config set <key> <value> | get [key] | list"
        Write-Host "Keys: $($validKeys -join ', ')"
      }
    }
  }

  "doctor" {
    Write-Step "checking chrome-devtools-mcp CLI..."
    $cli = Get-Command chrome-devtools -ErrorAction SilentlyContinue
    if (-not $cli) {
      Write-Step "chrome-devtools not found, installing: npm i -g chrome-devtools-mcp@latest ..."
      & npm i -g chrome-devtools-mcp@latest 2>$null
      $cli = Get-Command chrome-devtools -ErrorAction SilentlyContinue
      if ($cli) { Write-Step "installed chrome-devtools ($($cli.Source))" }
      else { Write-Step "FAILED - install manually: npm i -g chrome-devtools-mcp" }
    } else {
      Write-Step "chrome-devtools OK ($($cli.Source))"
    }

    Write-Step "checking Edge executable..."
    if (-not $Executable) {
      $candidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
      )
      $found = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($found) {
        if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
        $cfg = Read-Config
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
        $cfg | Add-Member -NotePropertyName "executable" -NotePropertyValue $found -Force
        $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding utf8
        $Executable = $found
        Write-Step "Edge detected + saved to config: $found"
      } else {
        Write-Step "Edge NOT found in default paths - set manually: cdt config set executable <path>"
      }
    } else {
      Write-Step "Edge OK ($Executable)"
    }

    Write-Step "checking default profile (for extension loading)..."
    if (-not (Read-Config).defaultProfile) {
      $def = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
      if (Test-Path $def) {
        $cfg = Read-Config
        if (-not $cfg) { $cfg = [PSCustomObject]@{} }
        $cfg | Add-Member -NotePropertyName defaultProfile -NotePropertyValue $def -Force
        ($cfg | ConvertTo-Json -Depth 10) | Set-Content -Path $ConfigFile -Encoding utf8
        Write-Step "default profile detected + saved: $def"
      } else {
        Write-Step "default profile NOT found - set manually: cdt config set defaultProfile <path>"
      }
    } else {
      $dp = [string](Read-Config).defaultProfile
      if (Test-Path $dp) { Write-Step "default profile OK ($dp)" }
      else { Write-Step "default profile configured but NOT found: $dp" }
    }
    $extCount = @(Get-InstalledExtensions).Count
    Write-Step "extensions in default profile: $extCount (configure: cdt extensions list)"

    Start-DaemonIfNotRunning | Out-Null
    $s = Invoke-RestMethod "$HttpBase/status" -ErrorAction Stop
    if (-not $s.extConnected) {
      # daemon 冷启后扩展还在 30s alarm 重连窗口里, 直接读 extConnected 会误报断连。宽限轮询覆盖该周期再判定。
      Write-Step "extension not connected yet, waiting up to 35s for reconnect (daemon may have just started)..."
      if (Wait-ExtensionConnected 35) {
        $s = Invoke-RestMethod "$HttpBase/status" -ErrorAction Stop
      } else {
        $s = $null
        Write-Step "extension NOT connected - run 'cdt extension' for the load path (start will fail until connected)"
      }
    }
    if ($s -and $s.extConnected) {
      Write-Step "extension connected, cached cookies: $($s.cachedCookieCount)"
      # inject 预检: 实际用 puppeteer 起一个 headless Edge 注入 cookie, 验证 start 能否成功。
      # /status 是浅检(daemon活+扩展连+缓存cookie), 不证明 puppeteer 能起 Edge; 此预检补上这层, 消除"doctor 全绿但 start 失败"。
      Write-Step "probing inject (headless Edge launch)..."
      $probeProfile = Join-Path $ProfilesDir "cdt-doctor-probe"
      if (Test-Path $probeProfile) { Remove-Item $probeProfile -Recurse -Force -ErrorAction SilentlyContinue }
      try {
        $body = @{ userDataDir = $probeProfile; executablePath = $Executable; headless = $true } | ConvertTo-Json -Compress
        $pr = Invoke-RestMethod -Method POST -Uri "$HttpBase/inject" -Body $body -ContentType "application/json" -TimeoutSec 120 -ErrorAction Stop
        Write-Step "inject OK (headless Edge launched, $($pr.injected) cookies) - start should work"
      } catch {
        $pdetail = $null
        if ($_.Exception -and $_.Exception.Response) {
          try { $pr2 = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $prb = $pr2.ReadToEnd(); $pr2.Close(); $pj = $prb | ConvertFrom-Json -ErrorAction SilentlyContinue; if ($pj -and $pj.error) { $pdetail = [string]$pj.error } elseif ($prb) { $pdetail = $prb } } catch {}
        }
        Write-Step "inject FAILED - cdt start will likely fail too: $(if ($pdetail) { $pdetail } else { $_.Exception.Message })"
      } finally {
        if (Test-Path $probeProfile) { Remove-Item $probeProfile -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }
    Write-Step "doctor done."
  }

  "extension" {
    $extDir = Join-Path $Root "extension"
    Write-Host $extDir
    Write-Host ""
    Write-Host "Load in daily Edge: edge://extensions -> Developer mode (on) -> Load unpacked -> select the dir above"
  }

  "skills" {
    $sub = if ($args.Count -gt 1) { [string]$args[1] } else { "" }
    $targetsRaw = "claude,codex"
    for ($i = 2; $i -lt $args.Count; $i++) {
      $a = [string]$args[$i]
      if ($a -like "--targets=*") { $targetsRaw = $a.Substring("--targets=".Length) }
      elseif ($a -eq "--targets" -and ($i + 1) -lt $args.Count) { $targetsRaw = [string]$args[$i + 1]; $i++ }
    }
    if ($targetsRaw -eq "all") { $targets = @($TargetMap.Keys) }
    else { $targets = @($targetsRaw -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    switch ($sub) {
      "install"   { foreach ($t in $targets) { Install-SkillTo $t } }
      "update"    { foreach ($t in $targets) { Install-SkillTo $t } }
      "uninstall" { foreach ($t in $targets) { Uninstall-SkillFrom $t } }
      "status"    { foreach ($t in $targets) { Get-SkillStatus $t } }
      default {
        Write-Host "Usage: cdt skills install|status|update|uninstall [--targets claude,codex|all]"
        Write-Host "Targets: $($TargetMap.Keys -join ', '), all (default: claude,codex)"
      }
    }
  }

  "uninstall" {
    Write-Step "removing deployed cdt skill from all targets..."
    foreach ($t in @($TargetMap.Keys)) { Uninstall-SkillFrom $t }
    Write-Step "uninstalling the cdt npm package..."
    & npm uninstall -g "@arsonist-g/cdt" 2>$null
    Write-Step "done. Config/profiles/sessions remain in ~/.cdt/ - delete manually if desired:"
    Write-Host "    Remove-Item -Recurse $HOME\.cdt"
  }

  "sessions" {
    $sub = if ($args.Count -gt 1) { [string]$args[1] } else { "" }
    if (-not (Test-Path $SessionsDir)) { Write-Step "no sessions"; exit 0 }
    $markers = @(Get-ChildItem $SessionsDir -Filter "*.started" -ErrorAction SilentlyContinue)
    if ($markers.Count -eq 0) { Write-Step "no sessions"; exit 0 }
    switch ($sub) {
      "list" {
        foreach ($m in $markers) {
          $id = $m.BaseName
          $profile = Join-Path $ProfilesDir "cdt-$id"
          $hasProfile = Test-Path $profile
          $state = if (Test-DaemonAlive $id) { "alive" } else { "orphan" }
          Write-Host ("{0,-24} {1,-7} profile={2}" -f $id, $state, $(if ($hasProfile) { "yes" } else { "no" }))
        }
      }
      "clean" {
        $removed = Invoke-SessionClean
        if ($removed -gt 0) { Write-Step "cleaned $removed orphan session(s)" }
        else { Write-Step "no orphan sessions" }
      }
      default {
        Write-Host "Usage: cdt sessions list | clean"
        Write-Host "  list   - show all started sessions (alive/orphan) + profiles"
        Write-Host "  clean  - remove markers + profiles for sessions whose daemon is no longer running"
      }
    }
  }

  "extensions" {
    $ep = Get-DefaultProfile
    $sub = if ($args.Count -gt 1) { [string]$args[1] } else { "" }
    switch ($sub) {
      "list" {
        if (-not $ep) { Write-Step "default profile not found, run: cdt config set defaultProfile <path>"; exit 1 }
        $wl = Get-WhitelistIds
        $all = Get-InstalledExtensions
        if ($all.Count -eq 0) { Write-Step "no extensions found in $ep"; exit 0 }
        Write-Host ("  {0,-33} {1,-14} {2}" -f "ID","VERSION","NAME (*=whitelist)")
        foreach ($e in ($all | Sort-Object Name)) {
          $mark = if ($wl -contains $e.Id) { "*" } else { " " }
          Write-Host ("{0} {1,-33} {2,-14} {3}" -f $mark, $e.Id, $e.Version, $e.Name)
        }
        Write-Step "add/remove with: cdt extensions add|remove <name|id>"
      }
      "add" {
        if ($args.Count -lt 3) { Write-Host "Usage: cdt extensions add <name|id>"; exit 1 }
        $id = Resolve-ExtensionArgument ([string]$args[2])
        if (-not $id) { exit 1 }
        $wl = Get-WhitelistIds
        if ($wl -contains $id) { Write-Step "already in whitelist: $id"; exit 0 }
        $wl += $id
        Set-WhitelistIds $wl
        Write-Step "added to whitelist: $id"
      }
      "remove" {
        if ($args.Count -lt 3) { Write-Host "Usage: cdt extensions remove <name|id>"; exit 1 }
        $id = Resolve-ExtensionArgument ([string]$args[2])
        if (-not $id) { exit 1 }
        $wl = Get-WhitelistIds
        if ($wl -notcontains $id) { Write-Step "not in whitelist, nothing to remove: $id"; exit 0 }
        $wl = @($wl | Where-Object { $_ -ne $id })
        Set-WhitelistIds $wl
        Write-Step "removed from whitelist: $id"
      }
      default {
        Write-Host "Usage: cdt extensions list | add <name|id> | remove <name|id>"
        Write-Host "  list    - show installed extensions in the default profile (* = in default-load whitelist)"
        Write-Host "  add     - add an extension to the default-load whitelist (by name or ID)"
        Write-Host "  remove  - remove from whitelist"
      }
    }
  }

  default {
    # forward to chrome-devtools with --sessionId (2>$null drops disclaimer/stderr noise, keeps stdout result)
    if (-not $SessionId) {
      Write-Step "no --session specified. Run 'cdt start' to get a sessionId, then pass --session=<id>."
      exit 1
    }
    # 预案: 只转发经过 cdt start(已注入 cookie)的 session。否则 chrome-devtools 会静默起一个无登录态的空白 Edge。
    if (-not (Test-SessionStarted $SessionId)) {
      Write-Step "session '$SessionId' was not started - run 'cdt start --session=$SessionId' first."
      Write-Step "(without start, the browser would have no login cookies)"
      exit 1
    }
    $toolArgs = @()
    if ($args.Count -gt 1) { $toolArgs = @($args[1..($args.Count - 1)]) }
    Write-Step "$cmd --sessionId=$SessionId"
    & chrome-devtools $cmd --sessionId=$SessionId @toolArgs 2>$null
  }
}
