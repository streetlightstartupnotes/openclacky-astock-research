import { state, apiFetch, loadList, pollActive, restartPoll, startPoll, stopPoll, stopTick, emit } from "./store.js";
import { navigateToSession, showAlert, showConfirm } from "./utils.js";

export function bindEvents(root, render) {
  root.querySelector("#ar-new")?.addEventListener("click", () => { state.creating = true; render({ force: true }); });
  root.querySelector("#ar-research-select")?.addEventListener("change", (event) => {
    state.activeId = event.target.value; state.current = null; state.localElapsed = 0; restartPoll(); render({ force: true });
  });
  root.querySelector("#ar-cancel")?.addEventListener("click", () => { state.creating = false; render({ force: true }); });
  root.querySelectorAll("[data-analyst]").forEach((input) => input.addEventListener("change", () => {
    const key = input.dataset.analyst;
    state.draft.analysts = input.checked ? [...new Set([...state.draft.analysts, key])] : state.draft.analysts.filter((x) => x !== key);
    render({ force: true });
  }));
  root.querySelector("#ar-create")?.addEventListener("click", async () => {
    const ticker = root.querySelector("#ar-ticker")?.value.trim().toUpperCase();
    const tradeDate = root.querySelector("#ar-date")?.value;
    if (!/^((SH|SZ|BJ)?\d{6}(\.(SH|SZ|BJ))?)$/.test(ticker || "")) return showAlert("请输入 6 位 A 股代码");
    if (!tradeDate) return showAlert("请选择研究截止日");
    const quick = root.querySelector("#ar-quick-model")?.value || "";
    const deep = root.querySelector("#ar-deep-model")?.value || "";
    const models = {};
    ["market", "social", "news", "fundamentals", "policy", "hot_money", "lockup", "quality", "bull", "bear", "trader", "aggressive", "neutral", "conservative"].forEach((key) => { if (quick) models[key] = quick; });
    ["research_manager", "portfolio"].forEach((key) => { if (deep) models[key] = deep; });
    let research = null;
    try {
      research = await apiFetch("/researches", { method: "POST", body: JSON.stringify({
        ticker, trade_date: tradeDate, name: root.querySelector("#ar-name")?.value.trim() || "",
        analysts: state.draft.analysts, risk_profile: root.querySelector("#ar-risk")?.value || "balanced",
        max_concurrency: Number(root.querySelector("#ar-concurrency")?.value || 3),
        notes: root.querySelector("#ar-notes")?.value.trim() || "", models,
        entry_session_id: state.hostSessionId,
      }) });
      state.activeId = research.id; state.current = null; state.creating = false;
      const started = await apiFetch(`/orchestrations/${research.id}/start`, { method: "POST" });
      await loadList(); startPoll(); render({ force: true });
      if (started.orchestrator_session_id && started.orchestrator_session_id !== state.hostSessionId) {
        navigateToSession(started.orchestrator_session_id);
      }
    } catch (error) {
      // Creation and startup are separate API operations. If startup fails
      // (for example because this session is still answering), keep the
      // created project visible so the user can retry instead of showing an
      // apparently empty form.
      if (research) {
        await loadList().catch(() => {});
        state.creating = false;
        render({ force: true });
      }
      showAlert(error.message);
    }
  });
  root.querySelector("#ar-start")?.addEventListener("click", async () => {
    try {
      const data = await apiFetch(`/orchestrations/${state.activeId}/start`, { method: "POST" });
      startPoll();
      if (data.orchestrator_session_id && data.orchestrator_session_id !== state.hostSessionId) navigateToSession(data.orchestrator_session_id);
    }
    catch (error) { showAlert(error.message); }
  });
  root.querySelector("#ar-stop")?.addEventListener("click", async () => {
    if (!await showConfirm("停止当前投研并中断全部委员？")) return;
    await apiFetch(`/orchestrations/${state.activeId}/stop`, { method: "POST", headers: { "X-Caller": "user" } });
    stopTick(); pollActive();
  });
  root.querySelector("#ar-delete")?.addEventListener("click", async () => {
    const result = await showConfirm("删除这次投研？", { checkbox: "同时删除团队工作目录和报告" });
    if (!result?.ok) return;
    await apiFetch(`/orchestrations/${state.activeId}?delete_dirs=${result.checked}`, { method: "DELETE", headers: { "X-Caller": "user" } });
    state.activeId = null; state.current = null; stopPoll(); await loadList(); state.activeId = state.orchestrations[0]?.id || null; if (state.activeId) startPoll(); emit();
  });
  root.querySelectorAll("[data-jump]").forEach((button) => button.addEventListener("click", () => navigateToSession(button.dataset.jump)));
}
