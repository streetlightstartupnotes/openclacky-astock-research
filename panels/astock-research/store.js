const BASE_URL = "/api/ext/astock-research";
const today = new Date().toISOString().slice(0, 10);

export const state = {
  orchestrations: [], activeId: null, current: null, visible: false,
  hostSessionId: null, hostAgentProfile: null,
  pollTimer: null, pollInterval: 8000, tickTimer: null, localElapsed: 0,
  lastPollSignature: null,
  creating: false, presets: [], models: [], defaultModelId: null,
  draft: {
    ticker: "", trade_date: today, name: "", risk_profile: "balanced", max_concurrency: 3, notes: "",
    analysts: ["market", "social", "news", "fundamentals", "policy", "hot_money", "lockup"],
    quick_model: "", deep_model: "",
  },
};

/**
 * Resolve the session shown in the host UI. Some OpenClacky mount paths pass
 * an empty/stale ctx while the hash already points at the new session, so the
 * route is authoritative and the extension context is only a fallback.
 */
export function resolveHostSessionId(ctx = {}) {
  if (typeof window !== "undefined") {
    const match = (window.location?.hash || "").match(/^#session\/([^/?#]+)/);
    if (match) {
      try { return decodeURIComponent(match[1]); } catch (_) { return match[1]; }
    }
  }
  if (ctx.sessionId) return String(ctx.sessionId);
  try {
    const hostId = window.Clacky?.ext?.context?.sessionId;
    if (hostId) return String(hostId);
  } catch (_) { /* host context is an optional fallback */ }
  return null;
}

export function setHostContext(ctx = {}) {
  const nextSessionId = resolveHostSessionId(ctx);
  const changed = nextSessionId !== state.hostSessionId;
  state.hostSessionId = nextSessionId;
  state.hostAgentProfile = ctx.agentProfile || window.Clacky?.ext?.context?.agentProfile || null;
  if (changed) {
    state.orchestrations = [];
    state.activeId = null;
    state.current = null;
    state.localElapsed = 0;
    state.lastPollSignature = null;
    stopPoll();
    stopTick();
  }
}

const subscribers = new Set();
export function onChange(fn) { subscribers.add(fn); return () => subscribers.delete(fn); }
export function emit() { subscribers.forEach((fn) => fn()); }

export async function apiFetch(path, opts = {}) {
  const res = await fetch(BASE_URL + path, {
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) }, ...opts,
  });
  let data = null;
  try { data = await res.json(); } catch (_) { /* no body */ }
  if (!res.ok) throw new Error(data?.error || `HTTP ${res.status}`);
  return data;
}

export async function loadList() {
  const sessionQuery = state.hostSessionId ? `?session_id=${encodeURIComponent(state.hostSessionId)}` : "";
  const [list, presets, models] = await Promise.all([
    apiFetch(`/orchestrations${sessionQuery}`), apiFetch("/presets"), apiFetch("/models"),
  ]);
  state.orchestrations = list.orchestrations || [];
  state.activeId = state.activeId || list.active_id || state.orchestrations[0]?.id || null;
  state.presets = presets.analysts || [];
  state.models = models.models || [];
  state.defaultModelId = models.current_id || null;
  emit();
}

export async function pollActive() {
  if (!state.activeId || !state.visible) return;
  try {
    const data = await apiFetch(`/orchestrations/${state.activeId}/poll`);
    // The elapsed timer is updated locally once per second. Ignore it when
    // deciding whether to rebuild the whole panel; only structural state
    // changes should replace DOM.
    const signature = JSON.stringify({
      id: data.id,
      status: data.status,
      orchestrator_status: data.orchestrator_status,
      research: data.research,
      workers: data.workers,
      tasks: data.tasks,
      decision_log: data.decision_log,
    });
    const shouldRender = signature !== state.lastPollSignature;
    state.current = data;
    state.lastPollSignature = signature;
    if (typeof data.elapsed_seconds === "number") state.localElapsed = data.elapsed_seconds;
    if (data.status === "running") startTick(); else stopTick();
    if (shouldRender) emit();
  } catch (error) { console.debug("[astock-research] poll failed", error); }
}

export function startPoll() {
  stopPoll();
  state.pollTimer = setInterval(pollActive, state.pollInterval);
  pollActive();
}
export function stopPoll() { if (state.pollTimer) clearInterval(state.pollTimer); state.pollTimer = null; }
export function restartPoll() { if (state.activeId && state.visible) startPoll(); }
export function startTick() {
  if (state.tickTimer) return;
  state.tickTimer = setInterval(() => {
    state.localElapsed += 1;
    const el = document.getElementById("ar-elapsed");
    if (el) el.textContent = formatElapsed(state.localElapsed);
  }, 1000);
}
export function stopTick() { if (state.tickTimer) clearInterval(state.tickTimer); state.tickTimer = null; }
function formatElapsed(value) {
  const h = String(Math.floor(value / 3600)).padStart(2, "0");
  const m = String(Math.floor((value % 3600) / 60)).padStart(2, "0");
  const s = String(value % 60).padStart(2, "0");
  return `${h}:${m}:${s}`;
}
