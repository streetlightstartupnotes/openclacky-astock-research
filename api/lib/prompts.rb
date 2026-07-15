# ── Kickoff prompts + model name helpers ──────────────────────────────────
# Every session in an orchestration has its "identity" delivered on three layers:
#   L1  (compression-immune) — profile system_prompt (workflow, comms, principles)
#   L1.5 (compression-immune) — .clackyrules (orch_id, worker_id, working dir, teammates)
#   kickoff — the short first message this module produces
#
# The kickoff intentionally stays tiny to avoid dragging early tasks into
# the idle-compression window; anything long-lived belongs in L1 / L1.5.
module AstockResearch
  module Prompts
    # Leader kickoff — just a start trigger + current mode banner.
    def default_orchestrator_prompt(orch_or_id)
      orch = orch_or_id.is_a?(Hash) ? orch_or_id : nil
      mode = orch && orch["mode"].to_s

      if orch && orch["research"]
        research = orch["research"]
        return <<~PROMPT
          【系统】A 股投研任务已就绪。

          标的：#{research["ticker"]}
          研究截止日：#{research["trade_date"]}
          风险偏好：#{research["risk_profile"]}
          补充要求：#{research["notes"].to_s.empty? ? "无" : research["notes"]}

          立即读取 `.clackyrules`、`research.json` 与 `PIPELINE.md`，查询团队和任务，按依赖关系启动第一阶段分析师任务。无需再次询问用户目标，不得跳过数据质量、多空、交易和三方风险阶段。最终生成 `FINAL_REPORT.md`。
        PROMPT
      end

      if mode == "manual"
        # Manual orchestration: the user preconfigures the team. The Leader only
        # assigns work, records progress, and summarizes results. It must not
        # call POST /workers, PATCH /workers, or DELETE /workers to change the team.
        <<~PROMPT
          【系统】编排已启动 · **模式：手动编排**。

          本次团队和角色由用户预先配置好，你**不得**创建/修改/删除任何 Worker。
          - 禁止调 `POST /workers`、`PATCH /workers/:wid`、`DELETE /workers/:wid`。
          - 需要新增/调整成员时，明确告知用户由用户操作面板处理。
          - 你的职责仅限：向用户问好询问任务目标 → 按现有成员派活 → 记录进度 → 汇总结果。
          - 用户运行中追加需求时，也必须先查团队并派给现有 Worker；若缺少合适成员，要求用户在面板调整团队。

          按 system prompt 的「启动行为」向用户问好并询问本次任务目标；
          不清楚自己的 orch_id / 工作目录时先读工作目录根部的 .clackyrules。
        PROMPT
      else
        # Auto orchestration: the Leader builds the team according to the task.
        <<~PROMPT
          【系统】编排已启动 · **模式：AI 自动编排**。

          按 system prompt 的「启动行为」向用户问好并询问本次任务目标；
          拿到目标后由你根据任务组建团队、拆解、派活、汇总；
          用户运行中追加需求时，继续查团队、登记任务并派给 Worker；没有合适 Worker 时新增 Worker 后再派活；
          用户要求调整 Worker 长期职责时，优先删除旧 Worker 并创建职责完整的新 Worker；
          不清楚自己的 orch_id / 工作目录时先读工作目录根部的 .clackyrules。
        PROMPT
      end
    end

    # Worker kickoff — just its unique role_brief. Identity/teammates come
    # from .clackyrules; comms/reporting/recovery come from the profile.
    # team/comm/report kwargs kept for backwards compatibility.
    def default_worker_prompt(role, orch_id: nil, worker_id: nil, team: [], role_brief: nil)
      _ = [orch_id, worker_id, team]
      brief = (role_brief && !role_brief.strip.empty?) ? role_brief.strip : "负责按照 Leader 的指令完成对应任务。"

      <<~MSG
        【系统】你已加入编排团队，角色：#{role}。

        ## 你的职责
        #{brief}

        你的 worker_id、队友名单、工作目录写在工作目录根部的 .clackyrules 里（先读它）；
        通信/汇报方式、失忆自愈流程见你的 system prompt。等待 Leader 下达具体任务。
      MSG
    end

    # Translate a model reference (name — preferred, or legacy uuid) into a
    # human-readable label for logs/UI. Returns the default label for empty ref, the
    # name itself if it matches, or an ⚠️ marker if the ref is orphan (uuid
    # or name not in current catalog — happens after openclacky restart /
    # provider switch / model removal).
    def model_display_name(mref)
      return "默认" if mref.nil? || mref.to_s.strip.empty?
      ref = mref.to_s.strip
      ac = agent_config
      models = (ac&.models || [])
      # match by name (case-insensitive)
      hit = models.find { |x| x["model"].to_s.downcase == ref.downcase }
      return (hit["model"] || hit["id"]).to_s if hit
      # legacy: caller stored a uuid that still resolves
      hit = models.find { |x| x["id"] == ref }
      return (hit["model"] || hit["id"]).to_s if hit
      # orphan — surface it so the user sees "something's off"
      "⚠ #{ref[0, 24]}"
    rescue
      mref.to_s[0, 24]
    end
  end
end
