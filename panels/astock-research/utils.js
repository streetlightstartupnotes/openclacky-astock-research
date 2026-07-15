// ── Pure helpers — no DOM writes, no state ────────────────────────────────
// Small utilities shared across render/events/store. Keeps other modules
// import-only-what-they-need and easy to unit-test.

/** HTML-safe stringify. Handles null/undefined. */
export function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

/** HH:MM:SS from seconds. */
export function fmtElapsed(secs) {
  if (!secs) return "00:00:00";
  const h = String(Math.floor(secs / 3600)).padStart(2, "0");
  const m = String(Math.floor((secs % 3600) / 60)).padStart(2, "0");
  const s = String(secs % 60).padStart(2, "0");
  return `${h}:${m}:${s}`;
}

/** HH:MM from ISO timestamp. */
export function fmtTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

/**
 * Navigate to a Clacky session by clicking its sidebar item.
 * The host has no public jump API, so we click the DOM entry and retry until
 * it appears (fresh sessions render with delay).
 */
export function navigateToSession(sid, tries = 10) {
  if (!sid) return;
  const el = document.querySelector(`[data-session-id="${sid}"]`);
  if (el) { el.click(); return; }
  if (tries > 0) {
    setTimeout(() => navigateToSession(sid, tries - 1), 300);
  } else {
    console.debug("[astock-research] session item not found, cannot navigate:", sid);
  }
}

/**
 * Custom confirm dialog. `window.confirm` may be suppressed in Electron/webview.
 * @param {string} message
 * @param {{checkbox?: string}} [opts]
 * @returns {Promise<boolean | {ok:boolean, checked:boolean}>}
 */
export function showConfirm(message, opts) {
  const withCheckbox = opts && opts.checkbox;
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "oc-modal-overlay";
    overlay.dataset.ocModal = "confirm";
    overlay.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:99999;display:flex;align-items:center;justify-content:center";
    const checkboxHtml = withCheckbox ? `
      <label style="display:flex;align-items:center;gap:8px;margin-bottom:18px;font-size:12.5px;color:var(--color-text-secondary);cursor:pointer;user-select:none">
        <input type="checkbox" id="oc-confirm-check" style="cursor:pointer;margin:0">
        <span>${opts.checkbox}</span>
      </label>` : "";
    overlay.innerHTML = `
      <div style="background:var(--color-bg-primary);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg);padding:22px 26px;min-width:280px;max-width:360px;box-shadow:var(--shadow-lg);color:var(--color-text-primary);font-family:inherit">
        <div style="font-size:13px;line-height:1.6;margin-bottom:${withCheckbox ? "14px" : "18px"};color:var(--color-text-secondary)">${message}</div>
        ${checkboxHtml}
        <div style="display:flex;gap:8px;justify-content:flex-end">
          <button id="oc-confirm-cancel" style="padding:5px 14px;border-radius:var(--radius-sm);border:1px solid var(--color-border-primary);background:transparent;color:var(--color-text-secondary);cursor:pointer;font-size:13px">取消</button>
          <button id="oc-confirm-ok" style="padding:5px 14px;border-radius:var(--radius-sm);border:none;background:var(--color-error);color:#fff;cursor:pointer;font-size:13px;font-weight:600">确认</button>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    const result = (ok) => {
      const checked = withCheckbox ? !!overlay.querySelector("#oc-confirm-check").checked : false;
      return withCheckbox ? { ok: ok, checked: checked } : ok;
    };
    const cleanup = (ok) => { const r = result(ok); document.body.removeChild(overlay); resolve(r); };
    overlay.querySelector("#oc-confirm-ok").onclick     = () => cleanup(true);
    overlay.querySelector("#oc-confirm-cancel").onclick = () => cleanup(false);
    overlay.onclick = (e) => { if (e.target === overlay) cleanup(false); };
  });
}

/** Simple alert dialog for completed non-destructive actions. */
export function showAlert(message, okLabel = "OK") {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "oc-modal-overlay";
    overlay.dataset.ocModal = "alert";
    overlay.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:99999;display:flex;align-items:center;justify-content:center";
    overlay.innerHTML = `
      <div style="background:var(--color-bg-primary);border:1px solid var(--color-border-primary);border-radius:var(--radius-lg);padding:22px 26px;min-width:280px;max-width:360px;box-shadow:var(--shadow-lg);color:var(--color-text-primary);font-family:inherit">
        <div style="font-size:13px;line-height:1.6;margin-bottom:18px;color:var(--color-text-secondary)">${message}</div>
        <div style="display:flex;justify-content:flex-end">
          <button id="oc-alert-ok" style="padding:5px 14px;border-radius:var(--radius-sm);border:none;background:var(--color-accent-primary);color:#fff;cursor:pointer;font-size:13px;font-weight:600">${okLabel}</button>
        </div>
      </div>`;
    document.body.appendChild(overlay);
    const cleanup = () => { document.body.removeChild(overlay); resolve(true); };
    overlay.querySelector("#oc-alert-ok").onclick = cleanup;
    overlay.onclick = (e) => { if (e.target === overlay) cleanup(); };
  });
}

/**
 * Detect that the user is mid-interaction (form focus, hover on scroll region,
 * or a modal is open) — poll-driven re-renders should skip those moments to
 * avoid clobbering typing / scrolling.
 */
export function isUserInteracting(root) {
  if (!root) return false;
  if (document.querySelector(".oc-modal, .oc-modal-overlay, [data-oc-modal]")) return true;
  const active = document.activeElement;
  if (active && root.contains(active)) {
    const tag = (active.tagName || "").toLowerCase();
    if (tag === "select" || tag === "input" || tag === "textarea") return true;
    if (active.isContentEditable) return true;
  }
  const hover = root.querySelector(".oc-log-scroll:hover, .oc-task-scroll:hover");
  if (hover) return true;
  return false;
}

/**
 * Preserve every panel-owned scroll position across poll-driven innerHTML
 * replacement. The visible main scroller is `.ar-wrap` (not #oc-panel), so it
 * must be captured separately before buildPanel() replaces that DOM node.
 */
export function savePanelScroll(root) {
  if (!root) return null;
  const main = root.querySelector(".ar-wrap, .oc-wrap") || root;
  const nested = Array.from(root.querySelectorAll(".oc-log-scroll, .oc-task-scroll"))
    .map((element) => element.scrollTop);
  return { outer: root.scrollTop, main: main.scrollTop, nested };
}

export function restorePanelScroll(root, state) {
  if (!root || !state) return;
  root.scrollTop = state.outer || 0;
  const main = root.querySelector(".ar-wrap, .oc-wrap") || root;
  main.scrollTop = state.main || 0;
  const elements = Array.from(root.querySelectorAll(".oc-log-scroll, .oc-task-scroll"));
  elements.forEach((element, index) => {
    if (state.nested[index] != null) element.scrollTop = state.nested[index];
  });
}
