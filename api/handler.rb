# <astock-research extension root>/api/handler.rb
# ─────────────────────────────────────────────────────────────────────────────
# Multi-Agent Orchestrator — HTTP entrypoint.
#
# This file is intentionally thin: it wires the extension's helper modules
# into a single `Clacky::ApiExtension` subclass and hosts every HTTP route.
# Ruby's route DSL (`get`/`post`/…) only registers on the concrete subclass,
# so all routes have to live here; helper methods, however, come in via
# `include` from api/lib/*.rb — each file owns one concern:
#
#   • DataStore       — JSON persistence for orchestrations
#   • TeamDirs        — <workspace>/<team>/<worker>/ dir layout + .clackyrules
#   • SessionOps      — thin wrappers over host session registry + manager
#   • ErrorClassifier — A-class auto-retry / B-class escalate loop
#   • Prompts         — kickoff messages for Leader / Worker + model display
#   • Log             — decision_log append + msg summary + elapsed timer
#
# Only the public astock-research profile is registered with OpenClacky. The
# internal Leader/Worker policies are injected into project-local
# `.clackyrules`, so backend roles never leak into the New Session picker.
#
# Precedence when reading: routes here → helpers in lib/. When something
# breaks, start from the route body, follow the calls down.
# ─────────────────────────────────────────────────────────────────────────────

require "json"
require "time"
require "securerandom"
require "fileutils"
require "uri"
require "date"

# ── Load helper modules ────────────────────────────────────────────────
# Use `load` (not require_relative) so hot-reload of handler.rb also picks up
# edits to lib/*.rb. Openclacky's api_loader only tracks handler.rb mtime; if
# we required these once, changes to lib/* would be invisible until process
# restart. `load` re-executes on every handler reload, which is what we want
# during development. (In production handler.rb is loaded once too, so cost
# is identical either way.)
_ext_lib = File.expand_path("lib", __dir__)
%w[data_store team_dirs session_ops error_classifier prompts log research_presets].each do |m|
  load File.join(_ext_lib, "#{m}.rb")
end

class AstockResearchExt < Clacky::ApiExtension
  timeout 30

  # helpers — order roughly follows the read-path documented above
  include AstockResearch::DataStore
  include AstockResearch::TeamDirs
  include AstockResearch::SessionOps
  include AstockResearch::ErrorClassifier
  include AstockResearch::Prompts
  include AstockResearch::Log
  include AstockResearch::ResearchPresets

  # All sessions use the single public profile. Their runtime identity is
  # determined exclusively by the project-local `.clackyrules` written before
  # kickoff. This preserves one correct public entry while keeping internal
  # committee roles out of the agent picker.
  PUBLIC_PROFILE = "astock-research".freeze
  LEADER_PROFILE = PUBLIC_PROFILE
  WORKER_PROFILE = PUBLIC_PROFILE
  DEFAULT_ORCH_NAME = "New orchestration".freeze

  # Completion marker used in Worker → Leader reports. The Worker prompt
  # requires the first sentence to use this exact marker.
  # Match as a plain string, not a regex, to avoid false positives in free-form
  # Worker text where the same words appear later in the sentence.
  REPORT_DONE_MARKER = "任务已完成".freeze
  TERMINAL_TASK_STATUSES = %w[done superseded].freeze
  FINAL_REPORT_GRACE_SECONDS = 24
  FINAL_REPORT_RETRY_MAX = 3

  get "/presets" do
    json(analysts: research_presets, pipeline_stages: 7)
  end

  post "/researches" do
    body = required_json_body!
    entry_sid = body["entry_session_id"].to_s.strip
    unless entry_sid.empty?
      error!("entry session not found", status: 404) unless registry.ensure(entry_sid)
      profile = session_agent_profile(entry_sid)
      unless profile == PUBLIC_PROFILE
        error!("entry session must use the A股投研助手 profile", status: 422,
          session_id: entry_sid, agent_profile: profile)
      end
    end
    data = load_data
    unless entry_sid.empty?
      existing = data["orchestrations"].values.find { |o| o["entry_session_id"].to_s == entry_sid }
      if existing
        error!("this A股投研助手 session already owns a research project", status: 409,
          session_id: entry_sid, orchestration_id: existing["id"])
      end
    end
    orch = build_research_orchestration(body)
    orch["entry_original_working_dir"] = session_working_dir(entry_sid) unless entry_sid.empty?
    orch["orchestrator_prompt"] = default_orchestrator_prompt(orch)
    data["orchestrations"][orch["id"]] = orch
    data["active_id"] = orch["id"]
    append_log(orch, "user", "create_research", "创建 A 股投研 #{orch.dig("research", "ticker")}",
      type: "user_action", code: "log.research.created")
    save_data(data)
    json(orch)
  end

  def terminal_task_status?(status)
    TERMINAL_TASK_STATUSES.include?(status.to_s)
  end

  def orchestration_max_concurrency(orch)
    value = orch.dig("research", "max_concurrency").to_i
    AstockResearch::ResearchPresets::ALLOWED_CONCURRENCY.include?(value) ? value : AstockResearch::ResearchPresets::DEFAULT_CONCURRENCY
  end

  def running_task_count(orch)
    (orch["tasks"] || []).count { |task| task["status"] == "running" }
  end

  # Map a copied PIPELINE.md label such as "阶段 1 · 01 ..." back to the
  # fixed tasks[].name. This prevents duplicate shadow tasks when an LLM uses
  # the human-readable stage prefix in a progress call.
  def canonical_task_name(orch, value)
    raw = utf8_text(value).strip
    tasks = (orch["tasks"] || [])
    return raw if tasks.any? { |task| task["name"] == raw }

    normalized = raw.sub(/\A阶段\s*\d+\s*[·:：-]\s*/, "")
    tasks.any? { |task| task["name"] == normalized } ? normalized : raw
  end

  def orchestration_name_from_body(body)
    name = body["name"].to_s.strip
    name.empty? ? DEFAULT_ORCH_NAME : name
  end

  def research_tasks_terminal?(orch)
    tasks = (orch["tasks"] ||= [])
    tasks.any? && tasks.all? { |t| terminal_task_status?(t["status"]) }
  end

  def final_report_path(orch)
    dir = orch["orchestrator_dir"].to_s
    dir.empty? ? nil : File.join(dir, "FINAL_REPORT.md")
  end

  def final_report_ready?(orch)
    path = final_report_path(orch)
    path && File.file?(path) && File.size(path).positive?
  rescue
    false
  end

  def mark_orchestration_done_if_terminal!(orch)
    return false unless research_tasks_terminal?(orch)
    # In research mode the 16th Worker report is input to the Leader's final
    # synthesis, not the final deliverable itself. Do not tell the UI that the
    # project is done until FINAL_REPORT.md actually exists.
    return false if orch["mode"] == "research" && !final_report_ready?(orch)

    changed = orch["status"] != "done" || orch["stopped_at"].nil?

    orch["status"] = "done"
    orch["stopped_at"] ||= Time.now.iso8601
    orch.delete("final_report_idle_detected_at")
    orch.delete("final_report_error")
    changed
  end

  # Reconcile the short but important final-delivery phase after every fixed
  # task is done. It also repairs projects created by older versions that were
  # prematurely marked done before FINAL_REPORT.md was written.
  def reconcile_final_delivery!(orch)
    return false unless orch["mode"] == "research" && research_tasks_terminal?(orch)
    return mark_orchestration_done_if_terminal!(orch) if final_report_ready?(orch)

    changed = false
    if orch["status"] == "done"
      orch["status"] = "running"
      orch["stopped_at"] = nil
      changed = true
    end

    leader_status = session_status(orch["orchestrator_session_id"])
    if leader_status == "running"
      changed = true if orch.delete("final_report_idle_detected_at")
      return changed
    end
    return changed unless leader_status == "idle"

    now = Time.now
    first_seen = orch["final_report_idle_detected_at"]
    if first_seen.to_s.empty?
      orch["final_report_idle_detected_at"] = now.iso8601
      return true
    end
    return changed if now - Time.parse(first_seen) < FINAL_REPORT_GRACE_SECONDS

    retry_count = orch["final_report_resume_count"].to_i
    if retry_count < FINAL_REPORT_RETRY_MAX
      path = final_report_path(orch)
      prompt = <<~PROMPT
        【系统自动收尾】16 个固定任务均已完成，但最终交付文件仍不存在：#{path}

        请立即读取各委员报告，尤其是投资组合经理的最终组合决策，生成完整的 `FINAL_REPORT.md` 到团队根目录。不要重新运行已经完成的任务。写入文件后调用 `/decision` 记录最终摘要，并在主会话告知用户文件路径。
      PROMPT
      if wake_session(orch["orchestrator_session_id"], prompt,
          display_message: "自动收尾：生成 FINAL_REPORT.md")
        orch["final_report_resume_count"] = retry_count + 1
        orch["last_final_report_resume_at"] = now.iso8601
        orch.delete("final_report_idle_detected_at")
        append_log(orch, "system", "final_report_auto_resume",
          "固定任务已完成但最终报告缺失，自动唤醒主席收尾第 #{retry_count + 1} 次",
          type: "progress", params: { "retry" => retry_count + 1, "path" => path })
        changed = true
      end
    elsif orch["final_report_error"].to_s.empty?
      orch["final_report_error"] = "FINAL_REPORT.md 自动收尾已达 #{FINAL_REPORT_RETRY_MAX} 次上限"
      append_log(orch, "system", "final_report_auto_resume_exhausted",
        "最终报告自动收尾已达上限，需要人工检查主席模型",
        type: "error", params: { "path" => final_report_path(orch) })
      changed = true
    end
    changed
  rescue ArgumentError
    orch["final_report_idle_detected_at"] = Time.now.iso8601
    true
  end

  def required_json_body!
    raw = req.body.to_s
    error!("json body required") if raw.strip.empty?
    parsed = JSON.parse(raw)
    error!("json object required") unless parsed.is_a?(Hash)
    parsed
  rescue JSON::ParserError => e
    error!("invalid json body", detail: e.message)
  end

  # ── task lifecycle helpers ────────────────────────────────────────────────
  # Shared by the /progress and /message entry points.
  #
  # Applies three side effects together, idempotently:
  #   1. Find the task by name, or by the Worker's current_task, mark it done,
  #      and write done_at.
  #   2. Clear the Worker's current_task so it is idle from the scheduler view.
  #   3. When all tasks are terminal, mark the orchestration done and freeze
  #      stopped_at without overwriting the first timestamp.
  # `source` distinguishes Leader-driven /progress calls from /message fallback.
  # Returns false when the task is missing or already terminal so callers can
  # decide whether to error or ignore.
  def mark_task_done!(orch, worker_id:, task_name: nil, source: "leader")
    # Find the task by the supplied name first, then fall back to the Worker's current_task.
    tasks = (orch["tasks"] ||= [])
    if task_name.nil? || task_name.empty?
      w = (orch["workers"] || []).find { |x| x["id"] == worker_id }
      task_name = w&.dig("current_task")
    end
    return false if task_name.nil? || task_name.empty?

    task = tasks.find { |t| t["name"] == task_name }
    return false unless task
    return false if terminal_task_status?(task["status"])

    task["status"]  = "done"
    task["done_at"] = Time.now.iso8601
    task.delete("idle_detected_at")
    task.delete("auto_resume_exhausted_at")

    # Clear current_task so the Worker can receive another assignment.
    if worker_id
      w = (orch["workers"] || []).find { |x| x["id"] == worker_id }
      w["current_task"] = nil if w
    end

    # All terminal → freeze the orchestration.
    mark_orchestration_done_if_terminal!(orch)

    role = worker_id ? ((orch["workers"] || []).find { |x| x["id"] == worker_id }&.dig("role") || worker_id) : "orchestrator"
    append_log(orch, role, "done", "任务「#{task_name}」→ done",
      type: "progress",
      code: "log.task_progress",
      params: { "task" => task_name, "status" => "done", "source" => source })
    true
  end

  # ── routes ────────────────────────────────────────────────────────────────

  # Serve extension-owned report assets when a future panel view needs them.
  get "/asset" do
    rel = (query["path"] || "").to_s
    error!("missing path", status: 400) if rel.empty?

    root = File.expand_path(self.class.ext_dir.to_s)
    abs  = File.expand_path(File.join(root, rel))
    unless abs.start_with?(root + File::SEPARATOR) && File.file?(abs)
      error!("not found", status: 404)
    end

    ctype = case File.extname(abs).downcase
            when ".png"  then "image/png"
            when ".jpg", ".jpeg" then "image/jpeg"
            when ".gif"  then "image/gif"
            when ".webp" then "image/webp"
            when ".json" then "application/json; charset=utf-8"
            when ".svg"  then "image/svg+xml"
            else error!("unsupported", status: 415)
            end

    body = File.binread(abs)
    raise Clacky::ApiExtension::Halt.new(200, body, ctype)
  end

  get "/orchestrations" do
    data  = load_data
    session_id = query["session_id"].to_s.strip
    source = data["orchestrations"].values
    unless session_id.empty?
      source = source.select do |o|
        o["entry_session_id"].to_s == session_id ||
          o["orchestrator_session_id"].to_s == session_id ||
          (o["workers"] || []).any? { |w| w["session_id"].to_s == session_id }
      end
    end
    items = source.map do |o|
      {
        id:           o["id"],
        name:         o["name"],
        mode:         o["mode"],
        status:       o["status"],
        created_at:   o["created_at"],
        started_at:   o["started_at"],
        worker_count: (o["workers"] || []).size,
        task_count:   (o["tasks"] || []).size,
        done_count:   (o["tasks"] || []).count { |t| terminal_task_status?(t["status"]) },
        research:     o["research"]
      }
    end
    active_id = data["active_id"]
    active_id = items.first&.dig(:id) unless items.any? { |item| item[:id] == active_id }
    json(active_id: active_id, orchestrations: items)
  end

  post "/orchestrations" do
    data   = load_data
    id     = "orch_#{SecureRandom.hex(6)}"
    now    = Time.now.iso8601
    body   = json_body

    orch = {
      "id"                      => id,
      "name"                    => orchestration_name_from_body(body),
      "mode"                    => body["mode"] || "manual",
      "status"                  => "idle",
      "orchestrator_session_id" => nil,
      "orchestrator_prompt"     => nil,   # Filled below according to mode.
      "created_at"              => now,
      "started_at"              => nil,
      "workers"                 => [],
      "tasks"                   => [],
      "decision_log"            => []
    }

    orch["orchestrator_prompt"] = body["orchestrator_prompt"] || default_orchestrator_prompt(orch)

    data["orchestrations"][id] = orch
    save_data(data)
    json(orch)
  end

  # Optional model list for the frontend Worker model dropdown. Reuse the host
  # @agent_config.models, filter out auto-injected/media models, and return id
  # plus display name.
  get "/models" do
    ac = agent_config
    models = (ac&.models || [])
    list = models.each_with_index.map do |m, _i|
      next nil if m["auto_injected"]
      t = m["type"].to_s
      next nil if %w[image video audio ocr].include?(t)
      { "id" => m["id"], "name" => (m["model"] || m["id"]).to_s }
    end.compact
    current = (ac.respond_to?(:current_model) ? (ac.current_model rescue nil) : nil)
    current_id = current.is_a?(Hash) ? current["id"] : nil
    json(models: list, current_id: current_id)
  rescue Clacky::ApiExtension::Halt
    raise
  rescue => e
    logger.warn("[astock-research] list models failed: #{e.class}: #{e.message}")
    json(models: [], current_id: nil)
  end

  get "/orchestrations/:id" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    workers_enriched = (orch["workers"] || []).map do |w|
      w.merge(
        "status"        => (w["session_rebuild_pending"] ? "rebuild_pending" : session_status(w["session_id"])),
        "last_message"  => last_message_text(w["session_id"]),
        "error_state"   => w["error_state"],
        "error_message" => w["error_message"],
        "error_code"    => w["error_code"]
      )
    end

    json(orch.merge(
      "elapsed_seconds" => elapsed_seconds(orch),
      "orchestrator_status" => session_status(orch["orchestrator_session_id"]),
      "workers"         => workers_enriched
    ))
  end

  # Guard for stop/delete: reject AI-triggered calls that carry `x-caller: orchestrator`.
  def require_user_action!
    caller_header = req.header["x-caller"]&.first.to_s
    if caller_header == "orchestrator"
      error!("forbidden: stop/delete can only be triggered by the user via the panel", status: 403)
    end
  end

  delete "/orchestrations/:id" do
    require_user_action!
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    # The public entry session belongs to the user and must survive project
    # deletion. Backend-created controller sessions and all Worker sessions are
    # extension-owned and may be soft-deleted as before.
    entry_sid = orch["entry_session_id"].to_s.strip
    preserve_entry = !entry_sid.empty? && orch["orchestrator_session_id"].to_s == entry_sid
    all_team_sids = []
    all_team_sids << orch["orchestrator_session_id"] if orch["orchestrator_session_id"]
    (orch["workers"] || []).each { |w| all_team_sids << w["session_id"] if w["session_id"] }
    all_team_sids = all_team_sids.compact.uniq
    delete_sids = all_team_sids.reject { |sid| preserve_entry && sid.to_s == entry_sid }

    # Interrupt all running sessions first, reusing the stop flow:
    # registry.delete also raises the thread, but interrupt_session first:
    #   1) explicitly cancels idle_timer to avoid leftover timer callbacks;
    #   2) gives agents currently running LLM requests a chance to exit sooner
    #      (otherwise HTTP I/O may take tens of seconds to react to Thread#raise,
    #      wasting tokens);
    #   3) leaves logs for debugging.
    all_team_sids.each do |sid|
      begin
        @http_server&.send(:interrupt_session, sid)
      rescue => e
        logger.warn("[astock-research][delete] interrupt session #{sid} failed: #{e.message}")
      end
    end

    # delete each session from registry + disk (soft-delete to trash)
    reg = registry
    sm  = session_manager
    delete_sids.each do |sid|
      begin
        reg.delete(sid) if reg&.exist?(sid)
        sm.soft_delete(sid) if sm
        # broadcast to all clients so sidebar updates immediately (no manual refresh needed)
        @http_server&.send(:broadcast_all, type: "session_deleted", session_id: sid)
      rescue => e
        logger.warn("[astock-research] delete session #{sid} failed: #{e.message}")
      end
    end

    # Optionally clean the team working directory, including Worker subdirs,
    # Leader outputs, and injected .clackyrules. Move it to trash for a clean
    # teardown. Defaults to false: delete sessions only and keep work products.
    # WEBrick's req.query does not parse query strings for DELETE, so parse
    # query_string manually.
    # Move the preserved entry session out of the team directory before an
    # optional directory purge. This also returns the Files panel to its
    # pre-project location.
    restored_entry_dir = nil
    if preserve_entry
      original_dir = orch["entry_original_working_dir"].to_s.strip
      original_dir = workspace_dir if original_dir.empty?
      restored_entry_dir = original_dir if change_session_working_dir(entry_sid, original_dir)
    end

    del_dirs_flag = query["delete_dirs"] || params[:delete_dirs]
    if del_dirs_flag.nil? && req.query_string && !req.query_string.empty?
      qs = URI.decode_www_form(req.query_string).to_h rescue {}
      del_dirs_flag = qs["delete_dirs"]
    end
    if del_dirs_flag.to_s == "true"
      tdir = team_dir(orch)
      # Prefer deleting the team root once, which removes all subdirs. For
      # legacy data, also clean up any flat member dirs.
      purge_dir(tdir)
      (orch["workers"] || []).each { |w| purge_dir(w["dir"]) if w["dir"] && !w["dir"].start_with?(tdir) }
      purge_dir(orch["orchestrator_dir"]) if orch["orchestrator_dir"] && orch["orchestrator_dir"] != tdir && !orch["orchestrator_dir"].start_with?(tdir)
    end

    data["orchestrations"].delete(params[:id])
    data["active_id"] = nil if data["active_id"] == params[:id]
    save_data(data)
    json(deleted: params[:id], sessions_deleted: delete_sids,
      entry_session_preserved: (preserve_entry ? entry_sid : nil),
      entry_working_dir_restored: restored_entry_dir)
  end

  post "/orchestrations/:id/start" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    tdir = team_dir(orch)   # Team folder = Leader working directory.
    provision_research_runtime(tdir, orch) if orch["research"]

    # Always refresh rules and kickoff to the latest extension version.
    orch["orchestrator_prompt"] = default_orchestrator_prompt(orch)

    first_start = orch["started_at"].nil?
    is_resume = !first_start
    ldir = leader_dir(orch)
    write_leader_rules(ldir, orch_id: params[:id])

    # Session-first path: projects created from the public assistant panel bind
    # the already-open session as controller. The entry session is preserved on
    # project deletion; only its working directory is restored.
    entry_sid = orch["entry_session_id"].to_s.strip
    if !entry_sid.empty?
      error!("entry session not found", status: 409, session_id: entry_sid) unless registry.ensure(entry_sid)
      profile = session_agent_profile(entry_sid)
      unless profile == PUBLIC_PROFILE
        error!("entry session profile changed", status: 409,
          session_id: entry_sid, agent_profile: profile)
      end
      if first_start && session_status(entry_sid) == "running"
        error!("entry session is busy; wait for the current response to finish", status: 409,
          session_id: entry_sid)
      end
      orch["entry_original_working_dir"] ||= session_working_dir(entry_sid)
      unless change_session_working_dir(entry_sid, ldir)
        error!("failed to bind entry session working directory", status: 500,
          session_id: entry_sid, working_dir: ldir)
      end
      orch["orchestrator_session_id"] = entry_sid
      orch["orchestrator_dir"] = ldir
      orch["entry_session_owned"] = false
      rename_session_title(entry_sid, controller_session_title(orch))
    elsif orch["orchestrator_session_id"].nil?
      sid = create_session(
        name:        controller_session_title(orch),
        prompt:      nil,
        profile:     LEADER_PROFILE,
        working_dir: ldir
      )
      orch["orchestrator_session_id"] = sid.to_s
      orch["orchestrator_dir"]        = ldir
      orch["entry_session_owned"]     = true
    else
      # Legacy/API-created projects may already have a controller session.
      # Bring its display title up to the current naming convention on resume.
      rename_session_title(orch["orchestrator_session_id"], controller_session_title(orch))
    end

    # build team roster for worker prompts
    team = (orch["workers"] || []).map do |w|
      { role: w["role"], worker_id: w["id"] }
    end

    # create worker sessions if needed
    (orch["workers"] || []).each do |w|
      if w["session_id"]
        rename_session_title(w["session_id"], worker_session_title(orch, w))
        next
      end
      # Always rebuild the prompt from the full template, including communication
      # rules, and inject the role responsibilities as role_brief. For legacy
      # data, prefer role_brief and then fall back to the old prompt field.
      brief = w["role_brief"] || w["prompt"]
      w["prompt"] = default_worker_prompt(w["role"],
        orch_id:    params[:id],
        worker_id:  w["id"],
        team:       [{ role: "Leader", worker_id: "orchestrator" }] + team,
        role_brief: brief
      )
      wdir_w = worker_dir(orch, w["role"])
      write_worker_rules(wdir_w,
        orch_id:   params[:id],
        worker_id: w["id"],
        role:      w["role"],
        team:      team.reject { |m| m[:worker_id] == w["id"] }
      )
      sid = create_session_with_model(
        name:        worker_session_title(orch, w),
        # Provision the whole committee without starting 16 model turns. The
        # Leader wakes only dependency-ready Workers through /message; eagerly
        # submitting every kickoff exceeds OpenClacky's concurrency limit.
        prompt:      nil,
        profile:     WORKER_PROFILE,
        working_dir: wdir_w,
        model_id:    w["model_id"]
      )
      w["session_id"] = sid.to_s
      w["dir"]        = wdir_w
      w["session_rebuild_pending"] = nil
    end

    # Persist the complete roster and running state before waking the
    # controller. Otherwise a fast first API call from the Leader can observe
    # the old idle project with missing Worker session ids.
    orch["status"]     = "running"
    orch["started_at"] = Time.now.iso8601
    orch["stopped_at"] = nil
    data["active_id"]  = params[:id]
    append_log(orch, "system", "start",
      (is_resume ? "编排已恢复运行" : "编排已启动") + "，团队工作目录：#{tdir}",
      type: "system",
      code:   (is_resume ? "log.start.resumed" : "log.start.fresh"),
      params: { "workdir" => tdir })
    save_data(data)

    # First start always wakes the controller after persistence, regardless of
    # whether it is the bound public entry session or an API-created fallback.
    if first_start
      wake_session(
        orch["orchestrator_session_id"],
        orch["orchestrator_prompt"],
        display_message: "▶️ A股投研项目已启动"
      )
    elsif is_resume
      wake_session(
        orch["orchestrator_session_id"],
        "【系统】编排已从暂停中恢复。请回顾当前进度，继续协调团队推进未完成的任务；" \
        "如所有任务已完成则向用户汇报。工作目录：#{tdir}",
        display_message: "▶️ 恢复运行"
      )
      (orch["workers"] || []).each do |w|
        next unless w["session_id"]
        wake_session(
          w["session_id"],
          "【系统】编排已从暂停中恢复。若你有未完成的任务请继续；" \
          "否则等待 Leader 的下一步指令。工作目录：#{w["dir"] || worker_dir(orch, w["role"])}",
          display_message: "▶️ 恢复运行"
        )
      end
    end

    json(orch.merge("elapsed_seconds" => 0))
  end

  post "/orchestrations/:id/stop" do
    require_user_action!
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    # interrupt all running team sessions via the native interrupt_session method
    # (which also handles idle_timer cancellation, broadcasting, and status updates)
    team_sids = []
    team_sids << orch["orchestrator_session_id"] if orch["orchestrator_session_id"]
    (orch["workers"] || []).each { |w| team_sids << w["session_id"] if w["session_id"] }

    team_sids.each do |sid|
      begin
        @http_server.send(:interrupt_session, sid)
      rescue => e
        logger.warn("[astock-research] interrupt session #{sid} failed: #{e.message}")
      end
    end

    orch["status"]     = "idle"
    orch["stopped_at"] = Time.now.iso8601
    append_log(orch, "system", "stop", "编排已停止，所有 Agent 已中断",
      type: "system", code: "log.stop")
    save_data(data)
    json(orch)
  end

  get "/orchestrations/:id/poll" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    # ── Error detection and routing: Worker session error → class A self-heal
    # or class B escalation to Leader.
    error_handled = detect_and_handle_worker_errors!(orch)
    idle_recovered = recover_idle_running_tasks!(orch)
    final_delivery_handled = reconcile_final_delivery!(orch)

    workers_status = (orch["workers"] || []).map do |w|
      {
        id:            w["id"],
        role:          w["role"],
        session_id:    w["session_id"],
        model_id:      w["model_id"],
        status:        (w["session_rebuild_pending"] ? "rebuild_pending" : session_status(w["session_id"])),
        current_task:  w["current_task"],
        last_message:  last_message_text(w["session_id"]),
        error_state:   w["error_state"],
        error_message: w["error_message"],
        error_code:    w["error_code"]
      }
    end

    orch_status = session_status(orch["orchestrator_session_id"])
    any_running = workers_status.any? { |w| w[:status] == "running" } || orch_status == "running"

    # ── self-heal: freeze the timer if the orchestration is no longer running
    # but stopped_at was never written (e.g. finished via /progress all_done in
    # an older version, or any path that set status without stopping the clock).
    if !any_running && orch["status"] != "running" && orch["started_at"] && orch["stopped_at"].nil?
      orch["stopped_at"] = Time.now.iso8601
      save_data(data)
    elsif error_handled || idle_recovered || final_delivery_handled
      save_data(data)
    end

    json(
      id:                  params[:id],
      name:                orch["name"],
      research:            orch["research"],
      mode:                orch["mode"],
      status:              orch["status"],
      orchestrator_status: orch_status,
      orchestrator_session_id: orch["orchestrator_session_id"],
      workers:             workers_status,
      tasks:               orch["tasks"] || [],
      elapsed_seconds:     elapsed_seconds(orch),
      any_running:         any_running,
      decision_log:        (orch["decision_log"] || []).last(50)
    )
  end

  post "/orchestrations/:id/message" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    body      = json_body
    worker_id = body["worker_id"]
    content   = utf8_text(body["content"]).strip
    error!("content required") if content.empty?
    from_id     = body["from"].to_s
    from_role   = body["from_role"].to_s
    to_leader   = (worker_id == "orchestrator" || worker_id.nil?)
    from_leader = (from_id == "orchestrator" || from_id.empty?)

    # Some models correctly finish the report but accidentally copy their own
    # worker_id into the target field. A completion report sent Worker -> self
    # can never be useful and previously left the task permanently running.
    # Normalize this narrow, unambiguous mistake to Worker -> Leader.
    if orch["mode"] == "research" && !from_leader && !to_leader &&
        worker_id == from_id && content.include?(REPORT_DONE_MARKER)
      worker_id = "orchestrator"
      to_leader = true
    end

    # A Leader assignment is valid only after /progress successfully reserved
    # a running slot. This closes the race where an LLM ignores a 429 from
    # /progress and sends the fourth/fifth Worker message anyway.
    if orch["mode"] == "research" && from_leader && !to_leader
      assigned = (orch["tasks"] || []).find do |task|
        task["assigned_to"] == worker_id && task["status"] == "running"
      end
      unless assigned
        error!("worker has no running task; reserve a concurrency slot through /progress first",
          status: 409, worker_id: worker_id, max_concurrency: orchestration_max_concurrency(orch))
      end
    end

    target_sid = if worker_id == "orchestrator" || worker_id.nil?
      orch["orchestrator_session_id"]
    else
      w = (orch["workers"] || []).find { |x| x["id"] == worker_id }
      w&.dig("session_id")
    end

    error!("session not found", status: 400) unless target_sid
    unless registry.ensure(target_sid)
      error!("worker session missing", status: 409,
        worker_id: worker_id,
        session_id: target_sid,
        session_status: session_status(target_sid))
    end

    # Use wake_session instead of raw submit_task: the target session, especially
    # the Leader, may be busy. wake_session uses OpenClacky's native
    # submit_task(interrupt: true) path so interruption and message submission
    # happen as one operation.
    ok = wake_session(target_sid, content)
    error!("target session busy, message not delivered", status: 409) unless ok
    actor = if worker_id == "orchestrator" || worker_id.nil?
      "orchestrator"
    else
      (orch["workers"] || []).find { |x| x["id"] == worker_id }&.dig("role") || worker_id
    end
    log_type = if from_leader && !to_leader
      "dispatch"     # Leader → Worker: assignment
    elsif !from_leader && to_leader
      "report"       # Worker → Leader: report
    elsif !from_leader && !to_leader
      "chat"         # Worker → Worker: lateral chat
    else
      "message"      # Fallback, e.g. Leader → Leader odd cases.
    end

    log_actor = from_leader ? "orchestrator" : (from_role.empty? ? from_id : from_role)
    # Generate both localized fallback detail and code. The frontend translates
    # by code when possible and falls back to detail otherwise.
    detail, log_code = case log_type
      when "dispatch" then ["派活 → #{actor}",        "log.msg.dispatch"]
      when "report"   then ["汇报 → Leader",          "log.msg.report"]
      when "chat"     then ["→ #{actor}",             "log.msg.chat"]
      else                 ["向 #{actor} 发送消息",   "log.msg.default"]
    end
    append_log(orch, log_actor, "message", detail,
      type: log_type, summary: msg_summary(content), target: actor,
      code: log_code, params: { "target" => actor })

    # Fallback for Worker reports in both manual and auto modes: the Leader
    # prompt says "mark done after receiving a report", but in manual mode the
    # Leader session is not woken, so it never calls /progress. The result was
    # all Workers reporting done while task cards stayed orange/running.
    # Backend bypass: when a Worker → Leader report contains the completion
    # marker, use that Worker's current_task to trigger mark_task_done!. This is
    # idempotent; if the Leader later calls /progress manually, the helper
    # ignores the duplicate. This logic is mode-agnostic because auto mode is
    # already protected by the same helper.
    if log_type == "report" && content.include?(REPORT_DONE_MARKER)
      mark_task_done!(orch, worker_id: from_id, source: "worker_report")
    end

    save_data(data)
    json(sent: true)
  end

  # Leader records a directional decision/judgment. This only writes a log
  # entry and does not trigger behavior.
  post "/orchestrations/:id/decision" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    body    = json_body
    content = body["content"].to_s.strip
    error!("content required") if content.empty?
    actor   = (body["actor"].to_s.strip.empty? ? "orchestrator" : body["actor"].to_s)

    append_log(orch, actor, "decision", "决策",
      type: "decision", summary: content, code: "log.decision")
    save_data(data)
    json(recorded: true)
  end

  post "/orchestrations/:id/progress" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    body        = json_body
    worker_id   = body["worker_id"]
    task_name   = canonical_task_name(orch, body["task"])
    task_status = body["status"].to_s
    tasks       = (orch["tasks"] ||= [])

    if orch["mode"] == "research" && task_status == "running"
      existing = tasks.find { |task| task["name"] == task_name }
      reserving_new_slot = existing.nil? || existing["status"] != "running"
      limit = orchestration_max_concurrency(orch)
      if reserving_new_slot && running_task_count(orch) >= limit
        error!("research concurrency limit reached", status: 429,
          max_concurrency: limit, running_tasks: running_task_count(orch), task: task_name)
      end
    end

    if task_status == "superseded"
      error!("task required") if task_name.empty?
      task = tasks.find { |t| t["name"] == task_name }
      error!("task not found", status: 404) unless task

      if task["status"] == "superseded"
        json(updated: true, all_done: (orch["status"] == "done"))
      end

      task["status"] = "superseded"
      task["superseded_at"] = Time.now.iso8601
      task["superseded_by"] = body["superseded_by"].to_s
      task["superseded_reason"] = body["reason"].to_s

      (orch["workers"] || []).each do |w|
        next unless w["current_task"] == task_name || w["id"] == task["assigned_to"]

        w["current_task"] = nil if w["current_task"] == task_name
      end

      # Replaced tasks are usually followed by a new task registration. Avoid
      # briefly closing the orchestration between "old task superseded" and
      # "new task pending", but still close if the replacement already exists
      # and is terminal.
      replacement_name = task["superseded_by"].to_s
      replacement_task = tasks.find { |t| t["name"] == replacement_name }
      if replacement_name.empty? || (replacement_task && terminal_task_status?(replacement_task["status"]))
        mark_orchestration_done_if_terminal!(orch)
      end

      role = worker_id ? ((orch["workers"] || []).find { |x| x["id"] == worker_id }&.dig("role") || worker_id) : "orchestrator"
      append_log(orch, role, "superseded", "任务「#{task_name}」→ superseded",
        type: "progress",
        code: "log.task_superseded",
        params: {
          "task" => task_name,
          "status" => "superseded",
          "superseded_by" => task["superseded_by"],
          "reason" => task["superseded_reason"]
        })
      save_data(data)
      json(updated: true, all_done: (orch["status"] == "done"))
    end

    # The done branch uses the shared helper, the same code path as the Worker
    # report fallback in /message, to avoid duplicated semantics. The
    # running/pending branches keep their local update logic.
    # Note: route bodies are blocks executed via instance_exec, so `return`
    # would raise LocalJumpError. End the route with json(), which raises Halt.
    if task_status == "done"
      done_task_name = task_name
      if done_task_name.nil? || done_task_name.empty?
        done_task_name = (orch["workers"] || []).find { |x| x["id"] == worker_id }&.dig("current_task").to_s
      end
      existing_task = (orch["tasks"] || []).find { |t| t["name"] == done_task_name }
      error!("task not found", status: 404) unless existing_task
      if terminal_task_status?(existing_task["status"])
        json(updated: true, all_done: (orch["status"] == "done"))
      end
      updated = mark_task_done!(orch, worker_id: worker_id, task_name: task_name, source: "leader")
      error!("task not found", status: 404) unless updated
      save_data(data)
      json(updated: true, all_done: (orch["status"] == "done"))
    end

    task  = tasks.find { |t| t["name"] == task_name }
    if task
      task["status"] = task_status
      task["started_at"] = Time.now.iso8601 if task_status == "running" && task["started_at"].nil?
    elsif task_name.length > 0
      tasks << {
        "id"          => "task_#{SecureRandom.hex(4)}",
        "name"        => task_name,
        "status"      => task_status,
        "assigned_to" => worker_id,
        "deps"        => body["deps"] || [],
        "started_at"  => (task_status == "running" ? Time.now.iso8601 : nil),
        "done_at"     => nil
      }
    end

    if worker_id
      w = (orch["workers"] || []).find { |x| x["id"] == worker_id }
      if w
        w["current_task"] = task_name
        w["assigned_at"]  = Time.now.iso8601 if task_status == "running"
        rename_session_title(w["session_id"], worker_session_title(orch, w, task_name: task_name)) if task_status == "running"
      end
    end

    role = worker_id ? ((orch["workers"] || []).find { |x| x["id"] == worker_id }&.dig("role") || worker_id) : "orchestrator"
    append_log(orch, role, task_status, "任务「#{task_name}」→ #{task_status}",
      type: "progress",
      code: "log.task_progress",
      params: { "task" => task_name, "status" => task_status })
    save_data(data)
    json(updated: true, all_done: false)
  end

  post "/orchestrations/:id/workers" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    body = required_json_body!
    role = body["role"].to_s.strip
    error!("role required") if role.empty?

    w = {
      "id"           => "worker_#{SecureRandom.hex(4)}",
      "role"         => role,
      "session_id"   => nil,
      # Leader-customized role responsibilities, injected as role_brief into the
      # full template including communication rules, not used to replace the
      # whole prompt.
      "role_brief"   => body["prompt"].to_s,
      "model_id"     => (body["model_id"].to_s.strip.empty? ? nil : body["model_id"].to_s),
      "prompt"       => nil,
      "status"       => "idle",
      "current_task" => nil,
      "assigned_at"  => nil
    }
    (orch["workers"] ||= []) << w

    # If the orchestration is running, create a session for the new Worker
    # immediately. Otherwise session_id remains nil and the Leader would hit
    # "session not found" on the first assignment.
    if orch["status"] == "running"
      team = (orch["workers"] || []).map { |x| { role: x["role"], worker_id: x["id"] } }
      w["prompt"] = default_worker_prompt(w["role"],
        orch_id:    params[:id],
        worker_id:  w["id"],
        team:       [{ role: "Leader", worker_id: "orchestrator" }] + team,
        role_brief: w["role_brief"]
      )
      wdir_w = worker_dir(orch, w["role"])
      write_worker_rules(wdir_w,
        orch_id:   params[:id],
        worker_id: w["id"],
        role:      w["role"],
        team:      team.reject { |m| m[:worker_id] == w["id"] }
      )
      begin
        sid = create_session_with_model(
          name:        worker_session_title(orch, w),
          # Creating a role only provisions its session. Its first actual turn
          # begins when the Leader sends an assignment through /message.
          prompt:      nil,
          profile:     WORKER_PROFILE,
          working_dir: wdir_w,
          model_id:    w["model_id"]
        )
        w["session_id"] = sid.to_s
        w["dir"]        = wdir_w
        logger.info("[astock-research][add_worker] created session #{sid} for #{w["role"]}")
      rescue => e
        logger.warn("[astock-research][add_worker] create_session failed: #{e.message}")
      end
    end

    append_log(orch, "user", "add_worker", "添加角色「#{w["role"]}」",
      type: "user_action",
      code: "log.role.added",
      params: { "role" => w["role"] })
    save_data(data)
    json(w)
  end

  patch "/orchestrations/:id/workers/:wid" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch
    w = (orch["workers"] || []).find { |x| x["id"] == params[:wid] }
    error!("worker not found", status: 404) unless w

    body = json_body
    if body.key?("model_id")
      new_mid = body["model_id"].to_s.strip.empty? ? nil : body["model_id"].to_s
      changed = (w["model_id"] != new_mid)
      w["model_id"] = new_mid

      if changed
        sid = w["session_id"]
        # Path A: Worker has a live session → hot-switch and preserve all
        # conversation history, context, and tasks.
        # Path B: session not yet created, e.g. manual setup stage → only store
        # model_id and pass it through when create_session_with_model builds
        # the session; no live switch is needed.
        if sid && !new_mid.nil? && switch_session_model_hot(sid, new_mid)
          logger.info("[astock-research][patch_worker] hot-switched #{sid} -> #{new_mid}")
        elsif sid && new_mid.nil?
          # Switch back to the default model: the hot-switch API needs a concrete
          # id, so rebuild when there is no default id to switch to.
          rebuild_worker_session(orch, w, params[:id])
        elsif sid
          # Session exists but hot-switch failed, e.g. stale session → rebuild
          # to guarantee the new setting takes effect.
          logger.warn("[astock-research][patch_worker] hot-switch failed, rebuilding #{sid}")
          rebuild_worker_session(orch, w, params[:id])
        end
      end
      append_log(orch, "user", "set_model",
        "「#{w["role"]}」模型切换为 #{model_display_name(new_mid)}",
        type: "user_action",
        code: "log.set_model",
        params: { "role" => w["role"], "model" => model_display_name(new_mid) })

      # If the Worker is suspended on a user-actionable error (awaiting_user),
      # switching models counts as the user's decision. Wake it with a short
      # "continue" message and clear error_state.
      if changed && w["error_state"] == "awaiting_user" && w["session_id"]
        wake_session(w["session_id"],
          "已切换模型，请继续当前任务。",
          display_message: "已切换模型，继续任务")
        append_log(orch, w["role"], "error_resolved",
          "用户切换模型后自动恢复任务",
          type: "progress",
          code: "log.error_resolved.model_switched")
        w["error_state"]       = nil
        w["error_message"]     = nil
        w["error_code"]        = nil
        w["errored_at"]        = nil
        w["error_retry_count"] = 0
      end
    end

    save_data(data)
    json(w)
  end

  post "/orchestrations/:id/workers/:wid/restore_session" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    w = (orch["workers"] || []).find { |x| x["id"] == params[:wid] }
    error!("worker not found", status: 404) unless w
    sid = w["session_id"].to_s
    error!("session_id missing", status: 400) if sid.empty?

    unless restore_session_from_trash(sid)
      error!("session not found in file recall", status: 404,
        worker_id: w["id"],
        session_id: sid)
    end

    append_log(orch, "user", "restore_worker_session",
      "恢复角色「#{w["role"]}」的会话",
      type: "user_action",
      code: "log.role.session_restored",
      params: { "role" => w["role"] })
    save_data(data)
    json(w.merge("status" => session_status(sid)))
  end

  post "/orchestrations/:id/workers/:wid/rebuild_session" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    w = (orch["workers"] || []).find { |x| x["id"] == params[:wid] }
    error!("worker not found", status: 404) unless w

    old_sid = w["session_id"]
    w["session_id"] = nil
    w["session_rebuild_pending"] = nil

    if orch["status"] != "running"
      w["session_rebuild_pending"] = true
      append_log(orch, "user", "rebuild_worker_session_deferred",
        "角色「#{w["role"]}」将在下次启动时重建会话",
        type: "user_action",
        code: "log.role.session_rebuild_deferred",
        params: { "role" => w["role"], "old_session_id" => old_sid })
      save_data(data)
      json(w.merge("status" => "rebuild_pending", "deferred" => true))
    end

    rebuild_worker_session(orch, w, params[:id])
    error!("rebuild failed", status: 500) if w["session_id"].to_s.empty?

    if w["current_task"].to_s.strip.length > 0
      wake_session(w["session_id"],
        "你的旧会话已不可恢复，系统已为你重建会话。\n\n你是「#{w["role"]}」，当前任务是「#{w["current_task"]}」。请先阅读工作目录根部的 .clackyrules，按团队通信规则继续执行当前任务；如缺少上下文，向 Leader 请求补充。",
        display_message: "会话已重建，请继续当前任务")
    end

    append_log(orch, "user", "rebuild_worker_session",
      "重建角色「#{w["role"]}」的会话",
      type: "user_action",
      code: "log.role.session_rebuilt",
      params: { "role" => w["role"], "old_session_id" => old_sid, "new_session_id" => w["session_id"] })
    save_data(data)
    json(w.merge("status" => session_status(w["session_id"])))
  end

  delete "/orchestrations/:id/workers/:wid" do
    data = load_data
    orch = data["orchestrations"][params[:id]]
    error!("orchestration not found", status: 404) unless orch

    workers = orch["workers"] || []
    w = workers.find { |x| x["id"] == params[:wid] }
    error!("worker not found", status: 404) unless w

    if w["session_id"]
      begin
        @http_server&.send(:interrupt_session, w["session_id"])
      rescue => e
        logger.warn("[astock-research][remove_worker] interrupt #{w["session_id"]} failed: #{e.message}")
      end
      destroy_session(w["session_id"])
    end

    (orch["tasks"] || []).each do |task|
      next unless task["assigned_to"] == params[:wid]
      next if terminal_task_status?(task["status"])
      task["status"] = "pending"
      task["assigned_to"] = nil
    end

    orch["workers"] = workers.reject { |x| x["id"] == params[:wid] }
    append_log(orch, "user", "remove_worker", "移除角色「#{w["role"]}」",
      type: "user_action",
      code: "log.role.removed",
      params: { "role" => w["role"] })
    save_data(data)
    json(deleted: params[:wid])
  end
end
