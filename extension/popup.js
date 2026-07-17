// popup: 先读 storage(即时, worker 休眠也有) 再问 worker(实时并唤醒), 800ms 刷新

function render(s) {
  if (!s) return;
  document.getElementById("status").textContent = s.status || "idle";
  document.getElementById("dot").className = "dot " + (s.status || "idle");
  document.getElementById("count").textContent = (s.cookieCount || 0) + " cookie";
  document.getElementById("ws").textContent = s.wsUrl || "-";
  document.getElementById("last").textContent = s.lastEvent
    ? `${s.lastEvent.time} ${s.lastEvent.text}`
    : "-";
  document.getElementById("logs").textContent =
    (s.logs && s.logs.length ? s.logs.join("\n") : "(无日志)");
  // 滚到底
  const logs = document.getElementById("logs");
  logs.scrollTop = logs.scrollHeight;
}

async function refresh() {
  let stored = null;
  try {
    const { state } = await chrome.storage.session.get("state");
    stored = state;
  } catch {}
  if (stored) render(stored);
  try {
    const s = await chrome.runtime.sendMessage({ type: "getStatus" });
    if (s) render(s);
  } catch (e) {
    if (!stored) {
      document.getElementById("logs").textContent =
        "service worker 未响应: " + e.message;
    }
  }
}

document.getElementById("reset").addEventListener("click", async () => {
  try {
    await chrome.runtime.sendMessage({ type: "reset" });
  } catch {}
  setTimeout(refresh, 300);
});

refresh();
setInterval(refresh, 800);
