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
const child = spawn(
  "powershell.exe",
  ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1, ...args],
  { stdio: "inherit" }
);

child.on("exit", (code) => process.exit(code ?? 0));
