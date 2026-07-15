# Domain presets adapted from TradingAgents-Astock's graph and agent roles.
module AstockResearch
  module ResearchPresets
    ANALYSTS = {
      "market" => {
        role: "市场技术分析师", task: "01 技术面与量价分析",
        brief: "负责 K 线、量价、趋势、支撑阻力与技术指标。先运行 bundle --role market；必含最新收盘价、近30日涨跌、5/20日均量对比、至少3个指标和涨跌停/T+1影响。"
      },
      "social" => {
        role: "市场情绪分析师", task: "02 舆情与情绪分析",
        brief: "负责投资者情绪、讨论热度、情绪拐点与一致性交易风险。运行 bundle --role social；严格区分可观测新闻热度与推断，不把传闻当事实。"
      },
      "news" => {
        role: "新闻事件分析师", task: "03 新闻、公告与事件分析",
        brief: "负责公司、行业和宏观新闻。运行 bundle --role news；每个关键事件标注日期、来源、影响方向、时效和是否已被市场定价。"
      },
      "fundamentals" => {
        role: "基本面分析师", task: "04 基本面、财务与估值分析",
        brief: "负责估值、盈利、资产负债、现金流、盈利预测和行业比较。运行 bundle --role fundamentals；关注数据报告期、同比/环比、估值消化条件与财务异常。"
      },
      "policy" => {
        role: "政策分析师", task: "05 政策与监管分析",
        brief: "负责宏观、监管、产业、地方和国际政策传导。运行 bundle --role policy；给出发布机构、日期、政策层级、影响链、力度和时间窗口。"
      },
      "hot_money" => {
        role: "游资与资金流分析师", task: "06 游资、主力与北向资金分析",
        brief: "负责龙虎榜、主力资金、北向、热门题材与板块轮动。运行 bundle --role hot_money；识别接力、撤退、量价背离和 T+1 流动性陷阱。"
      },
      "lockup" => {
        role: "解禁与股东行为分析师", task: "07 解禁、减持与股东行为分析",
        brief: "负责限售解禁、股东减持、质押和供给冲击。运行 bundle --role lockup；量化未来90天事件、占比、时间窗和潜在冲击。"
      }
    }.freeze

    FIXED_ROLES = [
      ["quality", "数据质量官", "08 数据质量门控", "核验所有分析师报告的来源、截止日、完整性、一致性和前视偏差；输出 A-F 质量等级及可用/慎用/不可用字段。"],
      ["bull", "多头研究员", "09 多头论证", "基于已通过质量门控的材料构建最强多头论证，优先关注政策顺风、资金流入、盈利兑现、估值消化和解禁压力解除，并逐项回应空头风险。"],
      ["bear", "空头研究员", "10 空头论证", "基于已通过质量门控的材料构建最强空头论证，优先关注政策逆风、减持解禁、资金撤退、估值泡沫、T+1陷阱和财务质量，并逐项挑战多头假设。"],
      ["research_manager", "研究经理", "11 研究裁决与投资计划", "综合多空论证，按 Buy/Overweight/Hold/Underweight/Sell 五档给出研究评级、证据权重、关键假设、催化剂和失效条件。"],
      ["trader", "A股交易员", "12 研究性交易方案", "把研究计划转成可执行的研究性方案：入场区间、仓位区间、止损/止盈、时间窗口；强制考虑 T+1、板块涨跌停、100/200股最小单位、停牌和交易时段。"],
      ["aggressive", "激进风险委员", "13 激进风险审查", "从机会成本和进攻性仓位角度审查方案，说明在什么条件下可提高风险预算，以及最坏情形。"],
      ["neutral", "中性风险委员", "14 中性风险审查", "平衡收益与风险，检查证据强度、仓位、回撤、流动性和组合相关性，提出基准方案。"],
      ["conservative", "保守风险委员", "15 保守风险审查", "从资本保全角度审查尾部风险、政策突变、跌停无法退出、财务造假和退市风险，提出更严格约束。"],
      ["portfolio", "投资组合经理", "16 最终组合决策", "综合研究计划、交易方案和三方风控，给出最终评级、仓位区间、触发条件、撤销条件和观察清单；明确仅供研究。"]
    ].freeze

    def research_presets
      ANALYSTS.map do |key, value|
        { "key" => key, "role" => value[:role], "task" => value[:task] }
      end
    end

    def build_research_orchestration(body)
      ticker = body["ticker"].to_s.strip.upcase
      error!("ticker required") if ticker.empty?
      unless ticker.match?(/\A(?:(?:SH|SZ|BJ)?)\d{6}(?:\.(?:SH|SZ|BJ))?\z/)
        error!("ticker must be a 6-digit A-share code", status: 422)
      end

      trade_date = body["trade_date"].to_s.strip
      begin
        Date.iso8601(trade_date)
      rescue ArgumentError
        error!("trade_date must be YYYY-MM-DD", status: 422)
      end

      selected = Array(body["analysts"]).map(&:to_s).select { |key| ANALYSTS.key?(key) }.uniq
      selected = ANALYSTS.keys if selected.empty?
      id = "research_#{SecureRandom.hex(6)}"
      now = Time.now.iso8601
      workers = []
      task_by_key = {}

      selected.each do |key|
        preset = ANALYSTS.fetch(key)
        worker = research_worker(key, preset[:role], preset[:brief], body)
        workers << worker
        task_by_key[key] = research_task(preset[:task], worker, [], 1, key)
      end

      analyst_task_names = task_by_key.values.map { |task| task["name"] }
      fixed_tasks = {}
      FIXED_ROLES.each do |key, role, task_name, brief|
        worker = research_worker(key, role, brief, body)
        workers << worker
        deps, stage = case key
        when "quality" then [analyst_task_names, 2]
        when "bull", "bear" then [["08 数据质量门控"], 3]
        when "research_manager" then [["09 多头论证", "10 空头论证"], 4]
        when "trader" then [["11 研究裁决与投资计划"], 5]
        when "aggressive", "neutral", "conservative" then [["12 研究性交易方案"], 6]
        when "portfolio" then [["13 激进风险审查", "14 中性风险审查", "15 保守风险审查"], 7]
        end
        fixed_tasks[key] = research_task(task_name, worker, deps, stage, key)
      end

      title = body["name"].to_s.strip
      title = "#{ticker} · #{trade_date} A股投研" if title.empty?
      entry_session_id = body["entry_session_id"].to_s.strip
      entry_session_id = nil if entry_session_id.empty?
      {
        "id" => id,
        "name" => title,
        "mode" => "research",
        "status" => "idle",
        # Session-first mode: a project created from the A股投研助手 panel is
        # bound to that already-open session. API-created/legacy projects may
        # omit it and fall back to a newly-created controller session.
        "entry_session_id" => entry_session_id,
        "entry_session_owned" => false,
        "entry_original_working_dir" => nil,
        "orchestrator_session_id" => entry_session_id,
        "orchestrator_prompt" => nil,
        "created_at" => now,
        "started_at" => nil,
        "stopped_at" => nil,
        "workers" => workers,
        "tasks" => task_by_key.values + fixed_tasks.values,
        "decision_log" => [],
        "research" => {
          "ticker" => ticker,
          "trade_date" => trade_date,
          "analysts" => selected,
          "risk_profile" => (body["risk_profile"].to_s.strip.empty? ? "balanced" : body["risk_profile"].to_s),
          "notes" => body["notes"].to_s.strip,
          "source_project" => "simonlin1212/TradingAgents-astock@e6b32a4f8223dc8c24cbf94fc7343caf6723738a"
        }
      }
    end

    def research_worker(key, role, brief, body)
      model_ref = body.dig("models", key).to_s.strip
      {
        "id" => "worker_#{SecureRandom.hex(4)}", "role" => role, "role_key" => key,
        "role_brief" => brief, "model_id" => (model_ref.empty? ? nil : model_ref),
        "prompt" => nil, "status" => "idle", "current_task" => nil, "assigned_at" => nil,
        "session_id" => nil
      }
    end

    def research_task(name, worker, deps, stage, role_key)
      {
        "id" => "task_#{SecureRandom.hex(4)}", "name" => name, "status" => "pending",
        "assigned_to" => worker["id"], "deps" => deps, "stage" => stage,
        "role_key" => role_key, "started_at" => nil, "done_at" => nil
      }
    end
  end
end
