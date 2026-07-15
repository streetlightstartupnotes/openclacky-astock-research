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
          if w["error_state"] && status != "error"
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
  end
end
