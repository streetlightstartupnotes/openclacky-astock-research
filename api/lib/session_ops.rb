# ── Session operations — thin wrappers around the host session registry ────
# Every function in this module goes through the host's `registry` /
# `session_manager` / `@http_server` — the orchestrator never manages sessions
# on its own. Failures degrade gracefully: return nil / false and log, so a
# broken session can never take down the whole extension.
module AstockResearch
  module SessionOps
    # Read-only metadata for binding an existing public A股投研助手 session to
    # a project. These helpers deliberately go through the native registry so
    # a stale or deleted session cannot be silently accepted.
    def session_agent(session_id)
      return nil if session_id.nil? || session_id.to_s.strip.empty?
      return nil unless registry.ensure(session_id)

      agent = nil
      registry.with_session(session_id) { |s| agent = s[:agent] }
      agent
    rescue => e
      logger.warn("[astock-research][session_agent] #{session_id} failed: #{e.message}")
      nil
    end

    def session_agent_profile(session_id)
      agent = session_agent(session_id)
      profile = agent&.agent_profile
      profile.respond_to?(:name) ? profile.name.to_s : nil
    rescue
      nil
    end

    def session_working_dir(session_id)
      agent = session_agent(session_id)
      dir = agent&.working_dir.to_s
      dir.empty? ? nil : File.expand_path(dir)
    rescue
      nil
    end

    # Rebind a live session to its dedicated research directory using the same
    # native mechanism as OpenClacky's working-directory picker. The change is
    # persisted and broadcast so Files/status UI follows immediately.
    def change_session_working_dir(session_id, new_dir)
      agent = session_agent(session_id)
      return false unless agent

      expanded = File.expand_path(new_dir.to_s)
      FileUtils.mkdir_p(expanded)
      agent.change_working_dir(expanded)
      session_manager.save(agent.to_session_data)
      @http_server&.send(:broadcast_session_update, session_id)
      true
    rescue => e
      logger.warn("[astock-research][change_working_dir] #{session_id} -> #{new_dir} failed: #{e.message}")
      false
    end

    # ── model resolution ─────────────────────────────────────────────────
    # openclacky model uuids are **regenerated every process start** (see
    # AgentConfig#parse_models — "ids are injected at load time and never
    # persisted"). So any uuid we save today is guaranteed to be invalid
    # after the next server restart. We therefore store the model **name**
    # (stable, human-readable, matches the label users see) and resolve it
    # to the current uuid only when actually calling openclacky.
    #
    # `model_ref` accepts either:
    #   - a name  ("gpt-5.3-codex")  — preferred, stable
    #   - a uuid                     — legacy data, best-effort match
    #   - nil / ""                   — use default
    # Returns a currently-valid uuid or nil (meaning: use default).
    def resolve_model_id(model_ref)
      return nil if model_ref.nil? || model_ref.to_s.strip.empty?
      ref = model_ref.to_s.strip
      models = (agent_config&.models || [])
      # exact name match (case-insensitive, matches switch_model_by_name semantics)
      hit = models.find { |m| m["model"].to_s.downcase == ref.downcase }
      return hit["id"] if hit
      # legacy: caller passed a uuid that happens to still be valid this run
      hit = models.find { |m| m["id"] == ref }
      return hit["id"] if hit
      nil
    rescue => e
      logger.warn("[astock-research][resolve_model_id] #{model_ref.inspect} failed: #{e.message}")
      nil
    end

    def session_restorable?(session_id)
      return false if session_id.nil? || session_id.to_s.strip.empty?

      (session_manager&.list_trash_sessions || []).any? do |s|
        s[:session_id].to_s.start_with?(session_id.to_s)
      end
    rescue => e
      logger.warn("[astock-research][session_restorable] #{session_id} failed: #{e.message}")
      false
    end

    # → "running" | "idle" | "error" | "unknown" | "missing_restorable" | "missing_unrestorable"
    def session_status(session_id)
      return "unknown" if session_id.nil?
      sess = registry.get(session_id)
      sess = registry.get(session_id) if sess.nil? && registry.ensure(session_id)
      return (session_restorable?(session_id) ? "missing_restorable" : "missing_unrestorable") unless sess
      case sess[:status]
      when :running then "running"
      when :error   then "error"
      else               "idle"
      end
    rescue
      "unknown"
    end

    def restore_session_from_trash(session_id)
      return false if session_id.nil? || session_id.to_s.strip.empty?
      return true if registry.get(session_id)
      return false unless session_manager&.restore_session(session_id)

      registry.ensure(session_id)
      session = registry.session_summary(session_id) rescue nil
      @http_server&.send(:broadcast_all, type: "session_restored", session: session)
      true
    rescue => e
      logger.warn("[astock-research][restore_session] #{session_id} failed: #{e.message}")
      false
    end

    # Returns { "message", "code", "raw" } if the session is in error state, else nil.
    def session_error_info(session_id)
      return nil if session_id.nil?
      sess = registry.get(session_id)
      return nil unless sess && sess[:status] == :error
      {
        "message" => sess[:error].to_s,
        "code"    => sess[:error_code].to_s,
        "raw"     => sess[:raw_message].to_s
      }
    rescue
      nil
    end

    # Send a prompt into a session, matching openclacky's native "new input
    # supersedes the current turn" behavior. submit_task(interrupt: true)
    # handles interrupting, joining briefly, and epoch fencing; doing that by
    # hand can leave us in the bad state where the old turn is interrupted but
    # the new prompt is never submitted.
    def wake_session(session_id, prompt, display_message: nil)
      return false if session_id.nil?

      safe_prompt = utf8_text(prompt)
      safe_display = display_message.nil? ? nil : utf8_text(display_message)
      submit_task(session_id, safe_prompt, display_message: safe_display, interrupt: true)
      true
    rescue => e
      logger.warn("[astock-research][wake] submit #{session_id} failed: #{e.message}")
      false
    end

    def compact_session_title_part(value, fallback, limit: 48)
      text = value.to_s.gsub(/\s+/, " ").strip
      text = fallback if text.empty?
      text.length > limit ? "#{text[0, limit]}…" : text
    end

    # User-facing session titles follow one stable scheme:
    #   角色｜股票代码/任务
    # This keeps the sidebar useful even when a full committee creates many
    # sessions with the same public agent profile.
    def controller_session_title(orch)
      ticker = compact_session_title_part(orch.dig("research", "ticker"), "未知标的", limit: 16)
      "投研总控｜#{ticker}/全流程协调"
    end

    def worker_session_title(orch, worker, task_name: nil)
      ticker = compact_session_title_part(orch.dig("research", "ticker"), "未知标的", limit: 16)
      role = compact_session_title_part(worker["role"], "研究角色", limit: 32)
      assigned_task = (orch["tasks"] || []).find { |task| task["assigned_to"] == worker["id"] }
      task = task_name || worker["current_task"] || assigned_task&.dig("name") || worker["role_brief"]
      task = compact_session_title_part(task, "待分配任务", limit: 48)
      "#{role}｜#{ticker}/#{task}"
    end

    def rename_session_title(session_id, title)
      return false if session_id.nil? || title.to_s.strip.empty?
      return false unless registry.ensure(session_id)

      agent = nil
      registry.with_session(session_id) { |session| agent = session[:agent] }
      return false unless agent

      agent.rename(title)
      session_manager.save(agent.to_session_data)
      @http_server.send(:broadcast_session_update, session_id)
      true
    rescue => e
      logger.warn("[astock-research][rename_session] #{session_id} failed: #{e.message}")
      false
    end

    # create_session (base class) doesn't pass model_id through, so we call
    # the host's build_session directly when a specific model is requested.
    # `model_ref` is a **model name** (preferred) or legacy uuid — resolved to
    # a currently-valid uuid via resolve_model_id. Falls back to the default
    # model on any failure or on unresolvable ref.
    def create_session_with_model(name:, prompt:, working_dir:, profile: "general", model_id: nil)
      resolved = resolve_model_id(model_id)
      return create_session(name: name, prompt: prompt, working_dir: working_dir, profile: profile) if resolved.nil?
      sid = @http_server.send(:build_session, name: name, working_dir: working_dir, profile: profile, source: :manual, model_id: resolved)
      submit_task(sid, prompt, display_message: nil) if prompt && !prompt.strip.empty?
      sid
    rescue => e
      logger.warn("[astock-research] create_session_with_model failed (#{model_id.inspect} -> #{resolved.inspect}): #{e.message}; fallback to default")
      create_session(name: name, prompt: prompt, working_dir: working_dir, profile: profile)
    end

    # Hot-swap the model on a live session (keeps history). Returns true on success.
    # `model_ref` — model name (preferred) or legacy uuid.
    def switch_session_model_hot(session_id, model_ref)
      return false if session_id.nil? || model_ref.to_s.strip.empty?
      return false unless registry.ensure(session_id)

      resolved = resolve_model_id(model_ref)
      return false if resolved.nil?

      agent = nil
      registry.with_session(session_id) { |s| agent = s[:agent] }
      return false if agent.nil?

      ok = agent.switch_model_by_id(resolved)
      return false unless ok

      session_manager.save(agent.to_session_data)
      @http_server.send(:broadcast_session_update, session_id)
      true
    rescue => e
      logger.warn("[astock-research][switch_model_hot] #{session_id} -> #{model_ref} failed: #{e.message}")
      false
    end

    # Fallback: destroy the old session and rebuild with the current model_id.
    # Loses history — only used when hot-swap isn't possible.
    def rebuild_worker_session(orch, w, orch_id)
      destroy_session(w["session_id"]) if w["session_id"]
      w["session_id"] = nil
      return unless orch["status"] == "running"

      team = (orch["workers"] || []).map { |x| { role: x["role"], worker_id: x["id"] } }
      w["prompt"] = default_worker_prompt(w["role"],
        orch_id:    orch_id,
        worker_id:  w["id"],
        team:       [{ role: "Leader", worker_id: "orchestrator" }] + team,
        role_brief: w["role_brief"]
      )
      wdir_w = worker_dir(orch, w["role"])
      write_worker_rules(wdir_w,
        orch_id:   orch_id,
        worker_id: w["id"],
        role:      w["role"],
        team:      team.reject { |m| m[:worker_id] == w["id"] }
      )
      begin
        sid = create_session_with_model(
          name:        worker_session_title(orch, w),
          # Rebuild the session in an idle state. The caller below wakes it
          # with a recovery prompt only when there is active work to resume.
          prompt:      nil,
          profile:     AstockResearchExt::WORKER_PROFILE,
          working_dir: wdir_w,
          model_id:    w["model_id"]
        )
        w["session_id"] = sid.to_s
        w["dir"]        = wdir_w
        w["session_rebuild_pending"] = nil
      rescue => e
        logger.warn("[astock-research][rebuild_worker_session] failed: #{e.message}")
      end
    end

    def destroy_session(sid)
      return if sid.nil?
      reg = registry
      sm  = session_manager
      reg.delete(sid) if reg&.exist?(sid)
      sm.soft_delete(sid) if sm
      @http_server&.send(:broadcast_all, type: "session_deleted", session_id: sid)
    rescue => e
      logger.warn("[astock-research] destroy_session #{sid} failed: #{e.message}")
    end

    def last_message_text(session_id)
      return nil if session_id.nil?
      sess = registry.get(session_id)
      return nil unless sess
      msg = sess[:raw_message].to_s
      msg.empty? ? nil : msg[0, 80]
    rescue
      nil
    end
  end
end
