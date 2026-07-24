#!/usr/bin/env node
// cdt CLI 入口 — 透传给 cdt.ps1(PowerShell wrapper, 已端到端验证)
// npm i -g . 之后, `cdt` 全局命令 = node 运行本文件。所有参数原样转发 powershell cdt.ps1。
// 选 node shim 而非 node 重写: 保留已验证的注入/登录态/三层清理逻辑, 且杀残留 Edge 靠 PS Get-CimInstance。
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ps1 = path.resolve(__dirname, "..", "cdt.ps1");
const args = process.argv.slice(2);

// powershell -File 透传: node spawn 把每个参数按需引号, 含空格/括号的值(如 Edge 路径、带空格的 fill 值)安全。
// stdio: stdin inherit, stdout/stderr 用 pipe 转发。powershell 及其子孙(chrome-devtools daemon/Edge)继承的是
// cdt.mjs 创建的 pipe, 不是 cdt.mjs 的 process.stdout(外部管道, 如 `cdt | head`)。cdt 命令结束 cdt.mjs exit →
// 关闭 process.stdout → 外部管道 EOF → head 正常退出。若 stdio 全 inherit, daemon 长期持有外部管道写端 →
// `cdt start | head` 永卡(实测)。PowerShell 层的 1>file 不改变 native 的 OS stdout handle, 治不了这个, 必须在此处修。
const child = spawn(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, ...args],
  { stdio: ["inherit", "pipe", "pipe"] }
);

child.stdout.pipe(process.stdout);
child.stderr.pipe(process.stderr);
// 两路退, 按命令类型自动选:
//  - close: tool 命令(无 daemon), powershell 退出后 stdio 全关, 立即退(无延迟)。
//  - exit 兜底: `cdt start` 起常驻 daemon, daemon 长期持有 child.stdout 写端 → close 永不触发;
//    靠 exit 后 800ms 把已缓冲输出 flush 到 process.stdout 再强制退。process.exit 关闭 process.stdout →
//    `cdt | head` 的 head 收到 EOF 正常退出(daemon 持的是 cdt.mjs 内部 pipe, 不是外部 head 管道)。
let exited = false;
const finish = (code) => { if (!exited) { exited = true; process.exit(code ?? 0); } };
child.on("close", (code) => finish(code));
child.on("exit", (code) => setTimeout(() => finish(code), 800));
