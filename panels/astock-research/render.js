import { state } from "./store.js";
import { escapeHtml, fmtElapsed, fmtTime } from "./utils.js";

const STAGES = {
  1: "多维研报", 2: "质量门控", 3: "多空辩论", 4: "研究裁决",
  5: "交易方案", 6: "三方风控", 7: "组合决策",
};

export function buildPanel() {
  return `<div class="oc-wrap ar-wrap">${toolbar()}${state.creating || !state.activeId ? createForm() : dashboard()}</div>`;
}

function toolbar() {
  const options = state.orchestrations.map((item) => {
    const ticker = item.research?.ticker ? `${item.research.ticker} · ` : "";
    return `<option value="${escapeHtml(item.id)}" ${item.id === state.activeId ? "selected" : ""}>${escapeHtml(ticker + item.name)}</option>`;
  }).join("");
  return `<div class="oc-toolbar ar-toolbar">
    <div><div class="oc-title">A股投研委员会</div><div class="ar-subtitle">TradingAgents × OpenClacky</div></div>
    <div class="oc-toolbar-actions">
      ${options ? `<select class="oc-select" id="ar-research-select">${options}</select>` : ""}
      <button class="oc-btn oc-btn--primary" id="ar-new">新建</button>
    </div>
  </div>`;
}

function createForm() {
  const draft = state.draft;
  const analysts = state.presets.map((item) => `
    <label class="ar-check ${draft.analysts.includes(item.key) ? "ar-check--on" : ""}">
      <input type="checkbox" data-analyst="${item.key}" ${draft.analysts.includes(item.key) ? "checked" : ""}>
      <span><b>${escapeHtml(item.role)}</b><small>${escapeHtml(item.task)}</small></span>
    </label>`).join("");
  const modelOptions = (selected) => `<option value="">使用 OpenClacky 默认模型</option>` + state.models.map((m) =>
    `<option value="${escapeHtml(m.name)}" ${m.name === selected ? "selected" : ""}>${escapeHtml(m.name)}</option>`).join("");
  return `<div class="oc-form ar-form">
    <div class="ar-form-hero"><span class="ar-kicker">NEW RESEARCH</span><h2>创建 A 股多 Agent 投研</h2><p>分析师可并行，后续阶段按依赖自动推进。全部结论仅供学习研究。</p></div>
    <div class="ar-grid2">
      <div class="oc-form-group"><label>股票代码</label><input class="oc-input" id="ar-ticker" placeholder="例如 600519" value="${escapeHtml(draft.ticker)}"></div>
      <div class="oc-form-group"><label>研究截止日</label><input class="oc-input" type="date" id="ar-date" value="${escapeHtml(draft.trade_date)}"></div>
    </div>
    <div class="oc-form-group"><label>研究名称（可选）</label><input class="oc-input" id="ar-name" placeholder="默认：代码 · 日期 A股投研" value="${escapeHtml(draft.name)}"></div>
    <div class="oc-form-group"><label>第一阶段分析师</label><div class="ar-analysts">${analysts}</div></div>
    <div class="ar-grid2">
      <div class="oc-form-group"><label>快速思考模型 · 分析/辩论/交易/风控</label><select class="oc-select oc-select--full" id="ar-quick-model">${modelOptions(draft.quick_model)}</select></div>
      <div class="oc-form-group"><label>深度思考模型 · 研究经理/组合经理</label><select class="oc-select oc-select--full" id="ar-deep-model">${modelOptions(draft.deep_model)}</select></div>
    </div>
    <div class="ar-grid2">
      <div class="oc-form-group"><label>风险偏好</label><select class="oc-select oc-select--full" id="ar-risk">
        <option value="conservative" ${draft.risk_profile === "conservative" ? "selected" : ""}>保守</option>
        <option value="balanced" ${draft.risk_profile === "balanced" ? "selected" : ""}>均衡</option>
        <option value="aggressive" ${draft.risk_profile === "aggressive" ? "selected" : ""}>进取</option>
      </select></div>
      <div class="oc-form-group"><label>补充要求</label><textarea class="oc-textarea" id="ar-notes" rows="3" placeholder="持仓背景、关注周期、需要重点验证的问题…">${escapeHtml(draft.notes)}</textarea></div>
    </div>
    <div class="oc-form-actions"><button class="oc-btn oc-btn--ghost" id="ar-cancel">取消</button><button class="oc-btn oc-btn--primary" id="ar-create">创建并启动</button></div>
  </div>`;
}

function dashboard() {
  const data = state.current;
  if (!data) return `<div class="oc-empty">正在载入投研状态…</div>`;
  const research = data.research || {};
  const tasks = data.tasks || [];
  const done = tasks.filter((t) => ["done", "superseded"].includes(t.status)).length;
  const pct = tasks.length ? Math.round(done * 100 / tasks.length) : 0;
  const running = data.status === "running";
  return `<div class="ar-dashboard">
    <section class="ar-hero">
      <div><span class="ar-kicker">${escapeHtml(research.trade_date || "A-SHARE RESEARCH")}</span><h2>${escapeHtml(research.ticker || data.name)}</h2><p>${escapeHtml(data.name || "")}</p></div>
      <div class="ar-hero-actions"><span class="ar-risk">${escapeHtml(research.risk_profile || "balanced")}</span><span id="ar-elapsed" class="oc-timer">${fmtElapsed(state.localElapsed)}</span></div>
    </section>
    <div class="ar-actions">
      <button class="oc-btn ${running ? "oc-btn--danger" : "oc-btn--primary"}" id="${running ? "ar-stop" : "ar-start"}">${running ? "停止" : (data.status === "done" ? "重新运行" : "启动投研")}</button>
      ${data.orchestrator_session_id && data.orchestrator_session_id !== state.hostSessionId ? `<button class="oc-btn oc-btn--ghost" data-jump="${escapeHtml(data.orchestrator_session_id)}">打开总控会话</button>` : ""}
      <button class="oc-btn oc-btn--ghost" id="ar-delete">删除</button>
    </div>
    <section class="ar-progress-card"><div class="ar-progress-head"><b>总进度</b><span>${done}/${tasks.length} · ${pct}%</span></div><div class="oc-progbar"><div class="oc-progfill" style="width:${pct}%"></div></div></section>
    <section class="ar-pipeline">${Object.entries(STAGES).map(([stage, label]) => stageCard(Number(stage), label, tasks, data.workers || [])).join("")}</section>
    ${agents(data.workers || [])}
    ${logs(data.decision_log || [])}
  </div>`;
}

function stageCard(stage, label, tasks, workers) {
  const items = tasks.filter((task) => Number(task.stage) === stage);
  if (!items.length) return "";
  const complete = items.every((task) => ["done", "superseded"].includes(task.status));
  const active = items.some((task) => task.status === "running");
  return `<article class="ar-stage ${complete ? "ar-stage--done" : active ? "ar-stage--active" : ""}">
    <header><span>${stage}</span><b>${label}</b><em>${complete ? "完成" : active ? "进行中" : "等待"}</em></header>
    <div>${items.map((task) => {
      const worker = workers.find((w) => w.id === task.assigned_to);
      const icon = task.status === "done" ? "✓" : task.status === "running" ? "●" : "○";
      return `<button class="ar-task" ${worker?.session_id ? `data-jump="${escapeHtml(worker.session_id)}"` : ""}><i>${icon}</i><span>${escapeHtml(task.name)}</span><small>${escapeHtml(worker?.role || "")}</small></button>`;
    }).join("")}</div>
  </article>`;
}

function agents(workers) {
  return `<section class="ar-card"><h3>委员会 · ${workers.length}</h3><div class="ar-agent-grid">${workers.map((w) =>
    `<button class="ar-agent" ${w.session_id ? `data-jump="${escapeHtml(w.session_id)}"` : ""}><span class="oc-dot oc-dot--${w.status === "running" ? "running" : "idle"}"></span><b>${escapeHtml(w.role)}</b><small>${escapeHtml(w.status || "idle")}</small></button>`).join("")}</div></section>`;
}

function logs(entries) {
  const rows = entries.slice().reverse().map((item) => `<div class="oc-logrow"><div class="oc-logrow-head"><span class="oc-logtime">${fmtTime(item.at)}</span><span class="oc-logactor">${escapeHtml(item.actor)}</span><span class="oc-logtype">${escapeHtml(item.type || item.action)}</span></div><div class="oc-logsummary">${escapeHtml(item.summary || item.detail || "")}</div></div>`).join("");
  return `<section class="ar-card ar-log"><h3>研究动态</h3><div class="oc-log-scroll">${rows || '<div class="oc-log-empty">暂无动态</div>'}</div></section>`;
}
