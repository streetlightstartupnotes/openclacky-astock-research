/**
 * AI Team panel — entry point.
 *
 * Loaded by openclacky as a non-module `<script>`. This entry bootstraps the
 * real ES modules via dynamic import (browsers support `import()` in scripts).
 *
 * Module layout — extend by editing the matching file, not this one:
 *
 *   i18n.js    — dictionary + t()               (add strings here)
 *   icons.js   — SVG constants + STATUS_DOT
 *   styles.css — panel styles                   (host serves it at /ext_ui/)
 *   utils.js   — pure helpers (escape, fmt, confirm, navigation)
 *   store.js   — state + apiFetch + poll loop   (data lives here, no DOM)
 *   render.js  — HTML builders (strings only, no DOM writes)
 *   events.js  — bindEvents + modals            (DOM listeners)
 *
 * view.js (this file) only wires the above into `Clacky.ext.ui.mount`.
 */
(function () {
  "use strict";

  const EXT_ID  = "astock-research";
  const PANEL_ID = "astock-research";
  const BASE = `/ext_ui/${EXT_ID}/panels/${PANEL_ID}`;

  // Inject the stylesheet once. Served by openclacky's ext_ui static route.
  function injectStyles() {
    if (document.getElementById("oc-styles-link")) return;
    const link = document.createElement("link");
    link.id = "oc-styles-link";
    link.rel = "stylesheet";
    link.href = `${BASE}/styles.css`;
    document.head.appendChild(link);
  }

  // Synchronous mini-i18n: keeps tab.label working before modules load.
  // Once the real i18n module is imported, we hand off to it via `_t`.
  const _TAB_TITLE = { zh: "A股投研", en: "A-Share Research" };
  let _tRef = null; // set after modulePromise resolves
  function _t(key) {
    if (_tRef) return _tRef(key);
    if (key === "title") {
      const I18n = (window.Clacky && window.Clacky.I18n) || window.I18n;
      const l = (I18n && I18n.lang && I18n.lang()) || "zh";
      return _TAB_TITLE[l] || _TAB_TITLE.zh;
    }
    return key;
  }

  if (!(window.Clacky && Clacky.ext && Clacky.ext.ui)) return;
  let cleanupMount = null;
  let mountSeq = 0;

  // Import ES modules lazily so the plain <script> works. All modules resolve
  // to the same origin (same-site), so no CORS concerns.
  const modulesPromise = Promise.all([
    import(`${BASE}/i18n.js`),
    import(`${BASE}/store.js`),
    import(`${BASE}/render.js`),
    import(`${BASE}/events.js`),
    import(`${BASE}/utils.js`),
  ]).then(([i18n, store, renderMod, eventsMod, utils]) => {
    _tRef = i18n.t;
    return {
      t: i18n.t,
      onLangChange: i18n.onLangChange,
      state: store.state,
      setHostContext: store.setHostContext,
      onChange: store.onChange,
      loadList: store.loadList,
      startPoll: store.startPoll,
      stopPoll:  store.stopPoll,
      stopTick:  store.stopTick,
      restartPoll: store.restartPoll,
      pollActive: store.pollActive,
      buildPanel: renderMod.buildPanel,
      bindEvents: eventsMod.bindEvents,
      isUserInteracting: utils.isUserInteracting,
      savePanelScroll: utils.savePanelScroll,
      restorePanelScroll: utils.restorePanelScroll,
    };
  });

  // Mount contract: Clacky.ext.ui.mount's renderFn is `(ctx) -> Node | string | null`
  // and MUST return synchronously. An `async function` here returns a Promise,
  // which the host treats as `null` and the panel stays blank. Any async setup
  // has to run inside `.then()` and populate the panel afterwards.
  Clacky.ext.ui.mount("session.aside", function (ctx) {
    const mountId = ++mountSeq;
    if (cleanupMount) cleanupMount();
    cleanupMount = null;
    injectStyles();

    const panel = document.createElement("div");
    panel.id = "oc-panel";
    panel.style.cssText = "height:100%;overflow-y:auto;";

    // Show a lightweight placeholder while modules load.
    panel.innerHTML = `<div style="padding:16px;color:var(--color-text-secondary);font-size:12px">Loading…</div>`;

    // Kick off async wire-up but DON'T await here — see the sync-return note above.
    modulesPromise.then((mods) => {
      if (mountId !== mountSeq) return;
      const { t, onLangChange, state, setHostContext, onChange, loadList, startPoll, stopPoll, stopTick,
              restartPoll, pollActive, buildPanel, bindEvents,
              isUserInteracting, savePanelScroll, restorePanelScroll } = mods;

      let userScrollUntil = 0;
      panel.addEventListener("scroll", () => {
        userScrollUntil = Date.now() + 800;
        // Scroll events do not bubble. Capture mode is required because the
        // actual right-sidebar scroller (`.ar-wrap`) is replaced on each render.
      }, { passive: true, capture: true });

      // Local render — protects user interaction and preserves log scroll.
      function render(opts) {
        const force = opts && opts.force;
        if (!force && isUserInteracting(panel)) return;
        // Do not replace the scrolling DOM while a wheel/touch gesture is in
        // progress. A later poll will render the newest state.
        if (!force && Date.now() < userScrollUntil) return;
        const savedScroll = force ? null : savePanelScroll(panel);
        panel.innerHTML = buildPanel();
        bindEvents(panel, render);
        restorePanelScroll(panel, savedScroll);
      }

      setHostContext(ctx || {});
      state.visible = true;

      // Pause polling when the panel scrolls out of view; resume when back.
      const observer = new IntersectionObserver((entries) => {
        const vis = entries[0].isIntersecting;
        state.visible = vis;
        if (vis) restartPoll();
        else { stopPoll(); stopTick(); }
      });
      observer.observe(panel);

      // Language change → re-render + update our tab button label.
      const unsubLangChange = onLangChange(() => {
        const tabBtn = document.querySelector('.aside-tab[data-tab="astock-research"] span');
        if (tabBtn) tabBtn.textContent = t("title");
        if (state.visible) render();
      });

      // Subscribe to store changes. The store is pub/sub: pollActive and other
      // async data sources call emit() after mutating state, and this callback
      // is what turns those emits into re-renders. Without this line the panel
      // would stay on "Loading…" forever.
      const unsubStore = onChange(() => { if (state.visible) render(); });

      cleanupMount = () => {
        observer.disconnect();
        unsubLangChange();
        unsubStore();
        state.visible = false;
        stopPoll();
        stopTick();
      };

      // Initial load.
      loadList().then(() => {
        if (mountId !== mountSeq) return;
        if (state.orchestrations.length > 0 && !state.activeId) {
          state.activeId = state.orchestrations[0].id;
        }
        render();
        if (state.activeId) startPoll();
      });
    }).catch((err) => {
      console.error("[astock-research] module load failed:", err);
      panel.innerHTML = `<div style="padding:16px;color:#c33;font-size:12px">Load failed: ${err.message}</div>`;
    });

    return panel;
  }, {
    // `label` is called at render time — swapping languages updates it live.
    tab:   { id: "astock-research", label: () => _t("title") },
    order: 150,
  });

  // The host does not call a tab's render function until that tab has already
  // been selected. Default activation must therefore run outside mount(), at
  // the tab-strip level. This tab exists only in attached astock-research
  // sessions, so ordinary sessions are unaffected.
  function installOwnTabAutoActivator() {
    if (window.__astockResearchAsideAutoActivator) return;
    window.__astockResearchAsideAutoActivator = true;
    const state = { attempts: 0, timer: null, session: "", opened: "" };
    const sessionKey = () => {
      const match = location.hash.match(/^#session\/([^/?]+)/);
      return match ? match[1] : "";
    };
    const schedule = (delay) => {
      if (state.timer) clearTimeout(state.timer);
      state.timer = setTimeout(tick, delay);
    };
    const tick = () => {
      state.timer = null;
      const session = sessionKey();
      if (!session || state.opened === session) return;
      if (state.session !== session) {
        state.session = session;
        state.attempts = 0;
      }
      const tab = document.querySelector('.aside-tab[data-tab="astock-research"]');
      if (tab) {
        if (!tab.classList.contains("active")) tab.click();
        if (tab.classList.contains("active")) {
          state.opened = session;
          return;
        }
      }
      if (state.attempts < 12) {
        state.attempts += 1;
        schedule(state.attempts < 6 ? 120 : 500);
      }
    };
    const observer = new MutationObserver(() => {
      const session = sessionKey();
      if (session && state.opened !== session && !state.timer) schedule(40);
    });
    observer.observe(document.body || document.documentElement, { childList: true, subtree: true });
    window.addEventListener("hashchange", () => {
      state.session = "";
      state.opened = "";
      state.attempts = 0;
      schedule(40);
    });
    [0, 80, 220, 520, 1000].forEach((delay) => setTimeout(tick, delay));
  }

  installOwnTabAutoActivator();

})();
