// cdt daemon — 常驻进程: WS server(扩展连) + HTTP server(cdt 按需调) + ping 保活 + cookie 注入
//   WS  : ws://127.0.0.1:17890   扩展主动连, 保持长连接
//   HTTP: http://127.0.0.1:17891
//        GET  /status   — 扩展连接状态 + 缓存 cookie 数
//        GET  /cookies  — 通过 WS 问扩展拿全量明文 cookie, 返回 JSON
//        POST /inject   — body {userDataDir, executablePath?, headless?} 注入 cookie 到隔离 profile 并关闭(写盘)
//
// 保活: 每 25s 向扩展发 ping(< service worker 30s 不活动阈值), 扩展 onmessage 重置计时器。

import { WebSocketServer } from "ws";
import { createServer } from "node:http";
import puppeteer from "puppeteer-core";

const WS_PORT = Number(process.env.CDT_WS_PORT || 17890);
const HTTP_PORT = Number(process.env.CDT_HTTP_PORT || 17891);
const PING_MS = 25000;
const EDGE =
  process.env.CDT_EXECUTABLE ||
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";

let ext = null;
let pendingCookies = null;
let lastCookies = null;
let lastCookieAt = 0;

const wss = new WebSocketServer({ port: WS_PORT });
console.log(`[daemon] WS   监听 ws://127.0.0.1:${WS_PORT}  (扩展连这里)`);

wss.on("connection", (ws) => {
  ext = ws;
  console.log("[daemon] 扩展已连接");
  ws.on("message", (raw) => {
    let m;
    try {
      m = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (m.type === "cookies") {
      lastCookies = m.data;
      lastCookieAt = Date.now();
      if (pendingCookies) {
        pendingCookies.resolve(m.data);
        pendingCookies = null;
      }
    } else if (m.type === "hello") {
      console.log("[daemon] 收到扩展 hello");
    } else if (m.type === "pong") {
      /* ping 回复, 隐式保活 */
    } else if (m.type === "error") {
      console.warn("[daemon] 扩展报错:", m.message);
      if (pendingCookies) {
        pendingCookies.reject(new Error(m.message));
        pendingCookies = null;
      }
    }
  });
  ws.on("close", () => {
    if (ext === ws) ext = null;
    console.log("[daemon] 扩展断开, 等待重连");
  });
  ws.on("error", () => {});
});

setInterval(() => {
  if (ext && ext.readyState === ext.OPEN) {
    ext.send(JSON.stringify({ type: "ping" }));
  }
}, PING_MS);

function fetchCookiesFromExt(timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    if (!ext || ext.readyState !== ext.OPEN) {
      reject(new Error("扩展未连接(请确认日常 Edge 已加载 CDT Bridge 且 daemon 在线)"));
      return;
    }
    if (pendingCookies) {
      reject(new Error("已有进行中的 cookie 请求"));
      return;
    }
    const timer = setTimeout(() => {
      if (pendingCookies) {
        pendingCookies.reject(new Error("扩展响应超时"));
        pendingCookies = null;
      }
    }, timeoutMs);
    pendingCookies = {
      resolve: (d) => {
        clearTimeout(timer);
        resolve(d);
      },
      reject: (e) => {
        clearTimeout(timer);
        reject(e);
      },
    };
    ext.send(JSON.stringify({ type: "getCookies" }));
  });
}

// chrome.cookies.Cookie → puppeteer Cookie(browser.setCookie 格式)
function toPuppeteerCookie(c) {
  const sameSiteMap = { strict: "Strict", lax: "Lax", no_restriction: "None" };
  const out = {
    name: c.name,
    value: c.value,
    domain: c.domain,
    path: c.path || "/",
    expires: c.expirationDate ? c.expirationDate : -1,
    httpOnly: !!c.httpOnly,
    secure: !!c.secure,
    sourceScheme: c.secure ? "Secure" : "NonSecure",
  };
  if (sameSiteMap[c.sameSite]) out.sameSite = sameSiteMap[c.sameSite];
  return out;
}

// 注入 cookie 到隔离 profile: 启动 Edge → setCookie → 优雅关闭(让 cookie 写盘)
async function injectCookies({ userDataDir, executablePath, headless = true }) {
  const exec = executablePath || EDGE;
  let cookies = lastCookies && lastCookies.length ? lastCookies : null;
  if (!cookies) cookies = await fetchCookiesFromExt();
  const pup = cookies.map(toPuppeteerCookie);
  const browser = await puppeteer.launch({
    executablePath: exec,
    userDataDir,
    headless: headless ? "new" : false,
    defaultViewport: null,
    args: [
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-popup-blocking",
    ],
  });
  try {
    await browser.setCookie(...pup);
  } finally {
    await browser.close();
  }
  return { injected: pup.length, profile: userDataDir, executablePath: exec };
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => (data += c));
    req.on("end", () => resolve(data));
    req.on("error", reject);
  });
}

const http = createServer(async (req, res) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  const url = new URL(req.url, `http://127.0.0.1:${HTTP_PORT}`);
  try {
    if (req.method === "GET" && url.pathname === "/status") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(
        JSON.stringify({
          extConnected: !!(ext && ext.readyState === ext.OPEN),
          cachedCookieCount: lastCookies ? lastCookies.length : 0,
          lastCookieAt: lastCookieAt || null,
        }),
      );
      return;
    }
    if (req.method === "GET" && url.pathname === "/cookies") {
      const cookies = await fetchCookiesFromExt();
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ count: cookies.length, data: cookies }));
      console.log(`[daemon] GET /cookies → 返回 ${cookies.length} 个`);
      return;
    }
    if (req.method === "POST" && url.pathname === "/inject") {
      const raw = await readBody(req);
      const body = raw ? JSON.parse(raw) : {};
      if (!body.userDataDir)
        throw new Error("缺少 userDataDir");
      const result = await injectCookies(body);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true, ...result }));
      console.log(
        `[daemon] POST /inject → 注入 ${result.injected} cookie 到 ${result.profile}`,
      );
      return;
    }
    res.writeHead(404, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  } catch (e) {
    res.writeHead(503, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ error: e.message }));
    console.warn("[daemon] HTTP 错误:", e.message);
  }
});

http.listen(HTTP_PORT, () => {
  console.log(`[daemon] HTTP 监听 http://127.0.0.1:${HTTP_PORT} (cdt 调这里)`);
  console.log(`[daemon]   GET  /status`);
  console.log(`[daemon]   GET  /cookies`);
  console.log(`[daemon]   POST /inject   {userDataDir, executablePath?, headless?}`);
  console.log("[daemon] 常驻中。Ctrl+C 退出。");
});
