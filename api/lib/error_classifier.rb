# ── Worker error classifier + escalation loop ─────────────────────────────
# Two classes:
#   A (auto_retry) — tool / JSON-parse errors → nudge the worker to continue.
#   B (need_user)  — auth / balance / invalid-model / network / unknown →
#                    freeze the worker and notify Leader; user picks a new
#                    model or intervenes.
#
# openclacky already retries rate_limit / network internally 10x; anything
# that bubbles up here means retrying more won't help, so we hand it back
# to the user by default (`:need_user` is the conservative default).
module AstockResearch
  module ErrorClassifier
    NEED_USER_CODES = %w[
      insufficient_credit invalid_model model_not_found
      auth_failed unauthorized quota_exceeded
    ].freeze
    NEED_USER_PATTERNS = [
      /余额不足/, /insufficient/i, /invalid.*model/i,
      /model.*not.*(found|exist)/i, /unauthorized/i, /api.?key/i,
      /quota/i, /rate.?limit/i, /too many request/i,
      /econnreset/i, /timeout/i, /network/i, /connection/i, /502|503|504/
    ].freeze
    AUTO_RETRY_PATTERNS = [
      /tool.*(error|failed)/i, /parse.*json/i, /json.*parse/i,
      /unexpected.*token/i
    ].freeze
    AUTO_RETRY_MAX = 2
    IDLE_RUNNING_GRACE_SECONDS = 24
    IDLE_RUNNING_RETRY_MAX = 3

    # Returns :need_user | :auto_retry
    def classify_error(info)
      return :need_user unless info
      code = info["code"].to_s
      return :need_user if NEED_USER_CODES.include?(code)
      msg = "#{info["message"]} #{info["raw"]}"
      return :auto_retry if AUTO_RETRY_PATTERNS.any? { |re| msg =~ re }
      return :need_user  if NEED_USER_PATTERNS.any?  { |re| msg =~ re }
      :need_user  # Unknown errors conservatively become class B to avoid blind, costly retries.
    end

    # Scan every worker in `orch`, react to new/cleared errors. Returns true
    # if any state changed (poll uses this to decide whether to save_data).
    def detect_and_handle_worker_errors!(orch)
      changed = false
      (orch["workers"] || []).each do |w|
        sid = w["session_id"]
        next unless sid

        info   = session_error_info(sid)
        status = session_status(sid)

        if info
          # Already handled this error → skip duplicate notifications/retries.
          next if w["error_state"]

          kind = classify_error(info)
          retry_count = (w["error_retry_count"] || 0).to_i
          # Class A after the retry cap → escalate to class B.
          kind = :need_user if kind == :auto_retry && retry_count >= AUTO_RETRY_MAX

          w["error_message"] = info["message"]
          w["error_code"]    = info["code"]
          w["errored_at"]    = Time.now.iso8601

          if kind == :auto_retry
            w["error_state"]       = "auto_retrying"
            w["error_retry_count"] = retry_count + 1
            append_log(orch, w["role"], "auto_retry",
              "工具/解析报错，自动重试第 #{retry_count + 1} 次：#{info["message"]}",
              type: "error")
            wake_session(sid, "刚才的执行出错了：#{info["message"]}\n请从上一步的错误恢复，继续当前任务。")
            # Also notify the Leader. No intervention is needed; this prevents
            # the Leader from waiting blindly or misreading the situation.
            leader_sid = orch["orchestrator_session_id"]
            if leader_sid
              wake_session(leader_sid,
                "【系统通知】Worker「#{w["role"]}」执行报错，系统正在让它自动重试" \
                "（第 #{retry_count + 1}/#{AUTO_RETRY_MAX} 次）：#{info["message"]}。" \
                "\n你不需要立即介入，等待它汇报即可；若多次重试后升级为需要人工处理的错误，系统会再次通知你。",
                display_message: "Worker「#{w["role"]}」自动重试中")
            end
            changed = true
          else
            w["error_state"] = "awaiting_user"
            append_log(orch, w["role"], "error_escalate",
              "遇到需要用户处理的错误：#{info["message"]}（等待切换模型/介入）",
              type: "error")
            # Notify the Leader, explicitly saying it must report to the user so
            # it does not merely think about the issue privately and keep waiting.
            leader_sid = orch["orchestrator_session_id"]
            if leader_sid
              wake_session(leader_sid,
                "【系统通知·需汇报用户】Worker「#{w["role"]}」遇到需要人工处理的错误：#{info["message"]}。" \
                "系统已暂停该 worker，不要再给它派活。\n" \
                "**你现在必须做两件事**：\n" \
                "1. 立即向用户汇报本次故障（说明是哪个 worker、什么错、影响哪个任务），" \
                "并给出建议（切换模型 / 修配置 / 跳过该任务）。\n" \
                "2. 汇报后停下来等用户回复，不要自作主张继续推进依赖该 worker 的任务。",
                display_message: "Worker「#{w["role"]}」报错，需汇报用户")
            end
            changed = true
          end
        else
          # Session is normal (idle/running/unknown). If error_state exists and
          # the session is back to running/idle, self-healing is complete.
          # Watchdog exhaustion is not a transient provider error. Keep it
          # visible until the user explicitly switches/rebuilds the model;
          # otherwise the next idle poll would incorrectly declare recovery.
          if w["error_state"] && status != "error" && w["error_code"] != "idle_resume_exhausted"
            if %w[running idle].include?(status)
              prev_state = w["error_state"]
              append_log(orch, w["role"], "error_recovered",
                "错误已恢复（#{prev_state}）", type: "progress") if prev_state == "auto_retrying"
              # Notify the Leader on recovery as well, especially for class B
              # awaiting_user recovery, which usually means the user switched
              # models and the Worker can receive tasks again.
              leader_sid = orch["orchestrator_session_id"]
              if leader_sid && prev_state == "awaiting_user"
                wake_session(leader_sid,
                  "【系统通知】Worker「#{w["role"]}」之前的错误已恢复（用户已介入），现在可以正常工作。" \
                  "请继续推进它负责的任务。",
                  display_message: "Worker「#{w["role"]}」已恢复")
              end
              w["error_state"]       = nil
              w["error_message"]     = nil
              w["error_code"]        = nil
              w["errored_at"]        = nil
              # Keep retry_count until orchestration ends so the per-Worker
              # cumulative retry cap remains enforced.
              changed = true
            end
          end
        end
      end
      changed
    end

    # A model turn can end without sending the required Worker -> Leader
    # completion report. The task then stays `running` while the underlying
    # session is already `idle`, leaving the whole pipeline stuck forever.
    #
    # Poll owns this lightweight watchdog: the first idle observation starts a
    # grace timer, and a later poll wakes the same Worker with its existing
    # assignment. Retries are deliberately capped so a broken model/config does
    # not create an infinite, costly loop.
    def recover_idle_running_tasks!(orch)
      return false unless orch["status"] == "running"

      changed = false
      now = Time.now
      workers = (orch["workers"] || []).each_with_object({}) { |w, memo| memo[w["id"]] = w }

      (orch["tasks"] || []).each do |task|
        next unless task["status"] == "running"

        worker = workers[task["assigned_to"]]
        next unless worker && worker["session_id"]
        next if worker["error_state"]

        status = session_status(worker["session_id"])
        if status == "running"
          changed = true if task.delete("idle_detected_at")
          next
        end
        next unless status == "idle"

        first_seen = task["idle_detected_at"]
        if first_seen.to_s.empty?
          task["idle_detected_at"] = now.iso8601
          changed = true
          next
        end

        idle_seconds = now - Time.parse(first_seen)
        next if idle_seconds < IDLE_RUNNING_GRACE_SECONDS

        retry_count = task["auto_resume_count"].to_i
        if retry_count < IDLE_RUNNING_RETRY_MAX
          prompt = <<~PROMPT
            【系统自动续跑】任务「#{task["name"]}」仍登记为 running，但你的会话已经空闲，说明上一次执行没有完成闭环。

            请从当前工作目录中的已有文件继续，不要从头重复已完成的工作。必须完成本任务产出，并按 system prompt 规定用“任务已完成”开头向主席汇报；不要停在思考、计划或等待状态。
          PROMPT
          if wake_session(worker["session_id"], prompt,
              display_message: "自动续跑：#{task["name"]}")
            task["auto_resume_count"] = retry_count + 1
            task["last_auto_resume_at"] = now.iso8601
            task.delete("idle_detected_at")
            worker["current_task"] ||= task["name"]
            append_log(orch, "system", "task_auto_resume",
              "Worker「#{worker["role"]}」空闲但任务仍在运行，自动续跑第 #{retry_count + 1} 次",
              type: "progress",
              params: { "task" => task["name"], "worker" => worker["role"], "retry" => retry_count + 1 })
            changed = true
          end
        elsif task["auto_resume_exhausted_at"].to_s.empty?
          task["auto_resume_exhausted_at"] = now.iso8601
          worker["error_state"] = "awaiting_user"
          worker["error_code"] = "idle_resume_exhausted"
          worker["error_message"] = "任务自动续跑已达 #{IDLE_RUNNING_RETRY_MAX} 次上限"
          append_log(orch, "system", "task_auto_resume_exhausted",
            "Worker「#{worker["role"]}」连续空闲，自动续跑已达上限，需要人工检查模型或数据源",
            type: "error", params: { "task" => task["name"], "worker" => worker["role"] })
          leader_sid = orch["orchestrator_session_id"]
          wake_session(leader_sid,
            "【系统通知·需汇报用户】任务「#{task["name"]}」已经自动续跑 #{IDLE_RUNNING_RETRY_MAX} 次，" \
            "Worker「#{worker["role"]}」仍未完成。请向用户说明卡点，停止继续派发依赖任务，等待人工处理。",
            display_message: "任务自动续跑已达上限") if leader_sid
          changed = true
        end
      rescue ArgumentError
        task["idle_detected_at"] = now.iso8601
        changed = true
      end

      changed
    end
  end
end
