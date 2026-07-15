# ── Team directory layout ──────────────────────────────────────────────────
# One directory per orchestration under <workspace>/<team_name>/, one
# sub-directory per worker under that. Leader writes into the team root; each
# worker writes into its own sub-dir. Directory names are sanitized. On
# tear-down we purge via openclacky's trash directory so the user can restore.
module AstockResearch
  module TeamDirs
    def internal_role_policy(role)
      file = role.to_s == "leader" ? "astock-chair" : "astock-member"
      path = File.join(File.expand_path(self.class.ext_dir.to_s), "agents", file, "system_prompt.md")
      File.read(path)
    rescue => e
      logger.warn("[astock-research] load internal #{role} policy failed: #{e.message}")
      raise
    end

    def provision_research_runtime(dir, orch)
      FileUtils.mkdir_p(dir)
      source = File.join(File.expand_path(self.class.ext_dir.to_s), "runtime")
      target = File.join(dir, "runtime")
      FileUtils.rm_rf(target)
      FileUtils.cp_r(source, target)

      File.write(File.join(dir, "research.json"), JSON.pretty_generate(orch["research"]))
      tasks = (orch["tasks"] || []).sort_by { |task| [task["stage"].to_i, task["name"].to_s] }
      pipeline = [
        "# A股投研流水线",
        "",
        "标的：#{orch.dig("research", "ticker")}",
        "研究截止日：#{orch.dig("research", "trade_date")}",
        "",
        "任务只能在全部依赖项完成后启动。",
        ""
      ]
      tasks.each do |task|
        deps = Array(task["deps"])
        # Keep the checkbox text exactly equal to tasks[].name; put metadata on
        # a separate line so the Leader cannot copy "阶段 N ·" into the API.
        pipeline << "- [ ] #{task["name"]}"
        pipeline << "  - 阶段=#{task["stage"]} · worker_id=#{task["assigned_to"]} · 依赖=#{deps.empty? ? "无" : deps.join("、")}"
      end
      File.write(File.join(dir, "PIPELINE.md"), pipeline.join("\n") + "\n")
    rescue => e
      logger.warn("[astock-research] provision runtime failed: #{e.message}")
      raise
    end

    # ~/clacky_workspace or whatever the host reports as default_working_dir
    def workspace_dir
      @http_server&.send(:default_working_dir) || File.expand_path("~/clacky_workspace")
    end

    # Sanitize the team name; fall back to the orchestration id when missing.
    def team_dir(orch)
      raw = orch["name"].to_s.strip
      raw = "team_#{orch["id"]}" if raw.empty?
      safe = raw.gsub(%r{[/\\:*?"<>|]}, "_")
      safe = "team_#{orch["id"]}" if safe.empty?
      File.join(workspace_dir, safe)
    end

    # Allocate a dedicated Worker directory: <workspace>/<team>/<role>/.
    def worker_dir(orch, role)
      safe = role.to_s.strip.gsub(%r{[/\\:*?"<>|]}, "_")
      safe = "worker" if safe.empty?
      File.join(team_dir(orch), safe)
    end

    # The Leader's working directory is the team folder itself. Outputs go in the team root.
    def leader_dir(orch)
      team_dir(orch)
    end

    # Write .clackyrules in the Worker directory to inject L1.5 dynamic identity,
    # which lands in system context and survives compression.
    def write_worker_rules(dir, orch_id:, worker_id:, role:, team:)
      FileUtils.mkdir_p(dir)
      team_lines = (team || []).map { |m| "  - #{m[:role]}（worker_id: #{m[:worker_id]}）" }.join("\n")
      team_lines = "  （暂无其他成员）" if team_lines.strip.empty?
      content = <<~RULES
        # A股投研内部运行上下文（由编排系统注入）

        - 上下文版本：ASTOCK_RESEARCH_CONTEXT_V1
        - 运行身份：worker

        - 你的角色：#{role}
        - 你的 worker_id：#{worker_id}
        - 当前编排 ID（orch_id）：#{orch_id}
        - 你的工作目录（绝对路径）：#{dir}
        - 共享研究配置：#{File.join(File.dirname(dir), "research.json")}
        - 共享数据工具：#{File.join(File.dirname(dir), "runtime", "astock_data.py")}

        ## ⚠️ 文件产出铁律（必须遵守）
        - 你的所有产出（代码、文档、素材等）必须写在你的工作目录 `#{dir}` 下。
        - 禁止在工作目录之外新建目录或文件；禁止把产出写到上级目录 / Leader 目录 / 其它成员目录 / 用户其它项目里。
        - 用相对路径即默认落在你的工作目录；如需绝对路径，必须以上面这个目录为前缀。

        ## 初始队友名单（可能已变动，需要最新名单时向 Leader 索要）
        - Leader（worker_id: orchestrator）
        #{team_lines}

        ## 上下文边界
        - 只允许使用本文件声明的 orch_id 和绝对路径。
        - 禁止搜索、读取或接管其它目录中的 `.clackyrules`、`research.json`、`PIPELINE.md`。
        - 如果共享研究配置或流水线不存在，立即向 Leader 报告阻塞，不得猜测身份。

        ## 内部委员规则

        #{internal_role_policy("worker")}
      RULES
      File.write(File.join(dir, ".clackyrules"), content)
    end

    # Write .clackyrules in the Leader directory to inject orch_id / wdir.
    def write_leader_rules(dir, orch_id:)
      FileUtils.mkdir_p(dir)
      content = <<~RULES
        # A股投研内部运行上下文（由编排系统注入）

        - 上下文版本：ASTOCK_RESEARCH_CONTEXT_V1
        - 运行身份：leader

        - 你是本团队的 Leader（负责人 / 协调者）
        - 当前编排 ID（orch_id）：#{orch_id}
        - 你的工作目录（团队文件夹，绝对路径）：#{dir}

        ## ⚠️ 文件产出铁律（必须遵守）
        - 你的工作目录就是本团队的根文件夹，各 Worker 的独立子目录都在它下面。
        - 你自己的所有产出（汇总文件、计划、报告等）直接写在团队文件夹 `#{dir}` 根部。
        - 禁止在团队文件夹之外新建目录或文件；禁止把产出写到用户其它项目里。
        - 各 Worker 有各自的子目录，需要他们的产出时通过消息索要，不要直接进他们的子目录改写。

        ## 上下文边界
        - 只允许使用本文件声明的 orch_id 和团队目录。
        - 禁止搜索、读取或接管其它目录中的 `.clackyrules`、`research.json`、`PIPELINE.md`。
        - 如果本目录缺少 `research.json` 或 `PIPELINE.md`，立即停止调度并向用户报告初始化失败。

        ## 内部主席规则

        #{internal_role_policy("leader")}
      RULES
      File.write(File.join(dir, ".clackyrules"), content)
    end

    # Delete a dedicated directory by moving it to trash; failures are non-fatal.
    def purge_dir(dir)
      return if dir.nil? || dir.to_s.strip.empty?
      return unless File.directory?(dir)
      # Safety guard: only delete directories under workspace, never the
      # workspace itself or external paths.
      ws = File.expand_path(workspace_dir)
      full = File.expand_path(dir)
      return if full == ws || !full.start_with?(ws + File::SEPARATOR)

      # Use openclacky's file-recovery trash so users can see and restore it in WebUI.
      require "clacky/utils/trash_directory"
      td = Clacky::TrashDirectory.new(ws)
      ts = Time.now.strftime("%Y%m%d_%H%M%S_%N")
      base = File.basename(full)
      dest = File.join(td.trash_dir, "#{base}_deleted_#{ts}")
      FileUtils.mkdir_p(td.trash_dir)
      FileUtils.mv(full, dest)
      meta = {
        "original_path"   => full,
        "trash_directory" => td.trash_dir,
        "deleted_at"      => Time.now.utc.iso8601,
        "deleted_by"      => "astock_research_ext",
        "file_size"       => 0,
        "file_type"       => "",
        "file_mode"       => "755"
      }
      File.write("#{dest}.metadata.json", JSON.pretty_generate(meta))
    rescue => e
      logger.warn("[astock-research] purge_dir #{dir} failed: #{e.message}")
    end
  end
end
