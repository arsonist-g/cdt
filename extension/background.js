// CDT Bridge — background service worker (MV3)
// 架构(v2): 扩展主动连本地 daemon 保持持久长连接, 被动响应 daemon 的 getCookies/ping。
// 保活: daemon 25s ping → onmessage 重置 30s 不活动计时器; chrome.alarms 30s 兜底重连。
// 去噪: 重连指数退避(2→60s 封顶), 只在状态变化时记日志, onerror 静默。

const WS_URL = "ws://127.0.0.1:17890";
const TAG = "[cdt-bridge]";
const MAX_LOGS = 30;
const ALARM = "cdt-keepalive";

const state = {
  status: "disconnected", // disconnected|connecting|connected
  wsUrl: WS_URL,
  cookieCount: 0,
  served: 0, // 累计响应 getCookies 次数
  lastEvent: null,
  logs: [],
};

let wsRef = null;
let backoff = 1000; // 重连退避 ms

function persist() {
  try {
    chrome.storage.session.set({ state }).catch(() => {});
  } catch {}
}

function log(text) {
  const time = new Date().toLocaleTimeString();
  state.logs.push(`${time} ${text}`);
  if (state.logs.length > MAX_LOGS) state.logs.shift();
  state.lastEvent = { time, text };
  console.log(TAG, text);
  persist();
}

function setStatus(s) {
  if (state.status !== s) {
    // 只在状态变化时记一条(去噪核心)
    state.status = s;
    log("状态 → " + s);
  }
  persist();
}

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg?.type === "getStatus") {
    sendResponse({ ...state });
    return false;
  }
  if (msg?.type === "reset") {
    backoff = 1000;
    log("手动重连");
    if (!wsRef) connect();
    sendResponse({ ok: true });
    return false;
  }
  return false;
});

function connect() {
  if (wsRef) return;
  setStatus("connecting");
  let ws;
  try {
    ws = new WebSocket(WS_URL);
    wsRef = ws;
  } catch (e) {
    log("WebSocket 构造失败: " + (e?.message || e));
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    backoff = 1000; // 连上即重置退避
    setStatus("connected");
    ws.send(JSON.stringify({ type: "hello" }));
  };

  ws.onmessage = async (event) => {
    let m;
    try {
      m = JSON.parse(event.data);
    } catch {
      return;
    }
    // 任何 message 事件本身都重置 service worker 的 30s 不活动计时器(隐式保活)
    if (m.type === "ping") {
      ws.send(JSON.stringify({ type: "pong" }));
      return;
    }
    if (m.type === "getCookies") {
      try {
        const cookies = await chrome.cookies.getAll({});
        state.cookieCount = cookies.length;
        state.served += 1;
        persist();
        ws.send(
          JSON.stringify({ type: "cookies", count: cookies.length, data: cookies }),
        );
        log(`响应 getCookies #${state.served}: ${cookies.length} cookie`);
      } catch (e) {
        ws.send(JSON.stringify({ type: "error", message: String(e) }));
        log("读 cookie 报错: " + (e?.message || e));
      }
    }
  };

  ws.onerror = () => {
    // 静默: 不每次记, 避免刷屏(状态变化在 onclose 统一处理)
  };

  ws.onclose = () => {
    if (wsRef === ws) wsRef = null;
    setStatus("disconnected");
    scheduleReconnect();
  };
}

function scheduleReconnect() {
  if (wsRef) return;
  const wait = backoff;
  backoff = Math.min(backoff * 2, 60000); // 指数退避, 60s 封顶
  if (wait <= 2000) log(`${wait}ms 后重连…`); // 只在快速重连期记一条, 慢速期不刷
  setTimeout(connect, wait);
}

// alarms 兜底: 每 30s 检查连接, 断了重连(worker 被 Chrome 杀后, alarm 触发会唤醒它)
chrome.alarms.onAlarm.addListener((a) => {
  if (a.name !== ALARM) return;
  if (!wsRef || wsRef.readyState !== WebSocket.OPEN) {
    if (!wsRef) connect();
  }
});

chrome.alarms.create(ALARM, { periodInMinutes: 0.5 }); // 30s, MV3 最小值

log("CDT Bridge service worker 启动 (持久长连接模式)");
connect();
