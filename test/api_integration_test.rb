# frozen_string_literal: true

require "json"
require "fileutils"
require "rubygems"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
TEST_DATA = File.join(Dir.tmpdir, "astock-research-test-#{Process.pid}")
ENV["ASTOCK_DATA_DIR"] = TEST_DATA

openclacky_spec = Gem::Specification.find_by_name("openclacky")
$LOAD_PATH.unshift(File.join(openclacky_spec.full_gem_path, "lib"))
require "clacky/utils/logger"
require "clacky/extension/api_extension"
load File.join(ROOT, "api", "handler.rb")
AstockResearchExt.ext_id = "astock-research"
AstockResearchExt.ext_dir = ROOT

FakeProfile = Struct.new(:name)

class FakeAgent
  attr_reader :agent_profile
  attr_accessor :working_dir, :name

  def initialize(profile:, working_dir:, name: "Session 1")
    @agent_profile = FakeProfile.new(profile)
    @working_dir = File.expand_path(working_dir)
    @name = name
    @model_id = nil
  end

  def rename(new_name); @name = new_name.to_s.strip; end

  def change_working_dir(dir)
    @working_dir = File.expand_path(dir)
    true
  end

  def switch_model_by_id(id)
    @model_id = id
    true
  end

  def to_session_data
    { "agent_profile" => @agent_profile.name, "working_dir" => @working_dir, "name" => @name }
  end
end

class FakeRegistry
  attr_reader :sessions, :deleted

  def initialize
    @sessions = {}
    @deleted = []
  end

  def add(id, profile:, working_dir:, status: :idle, name: "Session 1")
    @sessions[id] = { agent: FakeAgent.new(profile: profile, working_dir: working_dir, name: name), status: status }
  end

  def ensure(id); @sessions.key?(id); end
  def exist?(id); @sessions.key?(id); end
  def get(id); @sessions[id]; end

  def with_session(id)
    yield @sessions.fetch(id)
  end

  def delete(id)
    @deleted << id
    @sessions.delete(id)
  end

  def session_summary(id)
    s = @sessions[id]
    s && { id: id, agent_profile: s[:agent].agent_profile.name, working_dir: s[:agent].working_dir }
  end
end

class FakeSessionManager
  attr_reader :saved, :soft_deleted

  def initialize
    @saved = []
    @soft_deleted = []
  end

  def save(data); @saved << data; end
  def soft_delete(id); @soft_deleted << id; end
  def list_trash_sessions; []; end
  def restore_session(_id); false; end
end

class FakeAgentConfig
  attr_reader :models, :default_working_dir

  def initialize(default_working_dir)
    @default_working_dir = default_working_dir
    @models = [{ "id" => "11111111-1111-1111-1111-111111111111", "model" => "fake-model", "type" => "default" }]
  end

  def current_model; @models.first; end
end

class FakeHttpServer
  attr_reader :runs, :interrupts, :broadcasts, :registry, :session_manager, :agent_config
  attr_accessor :on_run

  def initialize(workspace)
    @registry = FakeRegistry.new
    @session_manager = FakeSessionManager.new
    @agent_config = FakeAgentConfig.new(workspace)
    @runs = []
    @interrupts = []
    @broadcasts = []
    @seq = 0
  end

  def default_working_dir; @agent_config.default_working_dir; end

  def build_session(name:, working_dir:, profile:, source:, model_id: nil, **_rest)
    @seq += 1
    id = "generated#{@seq.to_s.rjust(8, '0')}"
    @registry.add(id, profile: profile, working_dir: working_dir, status: :idle, name: name)
    @broadcasts << [:built, id, name, source, model_id]
    id
  end

  def run_session_task(id, prompt, display_message: nil)
    @on_run&.call(id, prompt)
    @runs << { id: id, prompt: prompt, display: display_message }
    true
  end

  def interrupt_session(id)
    @interrupts << id
    @registry.sessions[id][:status] = :idle if @registry.sessions[id]
    true
  end

  def broadcast_session_update(id); @broadcasts << [:session_update, id]; end
  def broadcast_all(**payload); @broadcasts << [:all, payload]; end
end

FakeRequest = Struct.new(:body, :query, :header, :query_string)

module TinyAssertions
  def assert(value, message = "assertion failed")
    raise message unless value
  end

  def refute(value, message = "refutation failed")
    raise message if value
  end

  def assert_equal(expected, actual, message = nil)
    raise(message || "expected #{expected.inspect}, got #{actual.inspect}") unless expected == actual
  end

  def refute_equal(expected, actual, message = nil)
    raise(message || "expected #{actual.inspect} to differ from #{expected.inspect}") if expected == actual
  end

  def assert_includes(collection, value)
    assert(collection.include?(value), "expected #{collection.inspect} to include #{value.inspect}")
  end

  def refute_includes(collection, value)
    refute(collection.include?(value), "expected #{collection.inspect} not to include #{value.inspect}")
  end

  def assert_empty(collection)
    assert(collection.empty?, "expected #{collection.inspect} to be empty")
  end

  def refute_empty(collection)
    refute(collection.empty?, "expected #{collection.inspect} not to be empty")
  end

  def flunk(message)
    raise message
  end
end

class AstockResearchApiIntegrationTest
  include TinyAssertions
  def setup
    FileUtils.rm_rf(TEST_DATA)
    @workspace = File.join(TEST_DATA, "workspace")
    FileUtils.mkdir_p(@workspace)
    @http = FakeHttpServer.new(@workspace)
    @entry_id = "entry00000001"
    @http.registry.add(@entry_id, profile: "astock-research", working_dir: @workspace, name: "hi")
  end

  def invoke(method, pattern, body: nil, params: {}, query: {}, headers: {})
    route = AstockResearchExt.routes.find { |r| r.method == method && r.pattern == pattern }
    raise "route missing: #{method} #{pattern}" unless route

    req = FakeRequest.new(body.nil? ? "" : JSON.generate(body), query, headers, nil)
    instance = AstockResearchExt.new(req: req, res: Object.new, route: route, params: params, http_server: @http)
    instance.invoke
    flunk("route did not halt")
  rescue Clacky::ApiExtension::Halt => e
    parsed = e.content_type.start_with?("application/json") ? JSON.parse(e.payload) : e.payload
    [e.status, parsed]
  end

  def valid_research
    {
      "ticker" => "600519", "trade_date" => "2026-07-15",
      "analysts" => ["market"], "risk_profile" => "balanced",
      "entry_session_id" => @entry_id
    }
  end

  def create_research
    status, body = invoke(:post, "/researches", body: valid_research)
    assert_equal 200, status
    body
  end

  def test_route_catalog_and_validation_contracts
    expected = %w[
      GET:/presets POST:/researches GET:/asset GET:/orchestrations POST:/orchestrations GET:/models
      GET:/orchestrations/:id DELETE:/orchestrations/:id POST:/orchestrations/:id/start
      POST:/orchestrations/:id/stop GET:/orchestrations/:id/poll POST:/orchestrations/:id/message
      POST:/orchestrations/:id/decision POST:/orchestrations/:id/progress POST:/orchestrations/:id/workers
      PATCH:/orchestrations/:id/workers/:wid POST:/orchestrations/:id/workers/:wid/restore_session
      POST:/orchestrations/:id/workers/:wid/rebuild_session DELETE:/orchestrations/:id/workers/:wid
    ]
    actual = AstockResearchExt.routes.map { |r| "#{r.method.to_s.upcase}:#{r.pattern}" }
    assert_equal expected, actual

    assert_equal 7, invoke(:get, "/presets")[1]["analysts"].size
    assert_equal 422, invoke(:post, "/researches", body: valid_research.merge("ticker" => "ABC"))[0]
    assert_equal 422, invoke(:post, "/researches", body: valid_research.merge("trade_date" => "bad"))[0]
    assert_equal 422, invoke(:post, "/researches", body: valid_research.merge("max_concurrency" => 4))[0]

    @http.registry.add("wrongprofile01", profile: "general", working_dir: @workspace)
    wrong = valid_research.merge("entry_session_id" => "wrongprofile01")
    assert_equal 422, invoke(:post, "/researches", body: wrong)[0]
    assert_equal 404, invoke(:post, "/researches", body: valid_research.merge("entry_session_id" => "missing"))[0]
  end

  def test_session_first_full_lifecycle_and_all_mutating_interfaces
    orch = create_research
    orch_id = orch.fetch("id")
    assert_equal @entry_id, orch["orchestrator_session_id"]
    assert_equal 10, orch["workers"].size
    assert_equal 3, orch.dig("research", "max_concurrency")

    # One public session owns one project.
    assert_equal 409, invoke(:post, "/researches", body: valid_research)[0]

    list_status, list = invoke(:get, "/orchestrations", query: { "session_id" => @entry_id })
    assert_equal 200, list_status
    assert_equal [orch_id], list["orchestrations"].map { |x| x["id"] }

    # Prove the controller sees persisted Worker ids before it is awakened.
    @http.on_run = lambda do |sid, _prompt|
      next unless sid == @entry_id
      persisted = JSON.parse(File.read(AstockResearch::DataStore::DATA_FILE))
      current = persisted.fetch("orchestrations").fetch(orch_id)
      assert_equal "running", current["status"]
      assert current["workers"].all? { |w| !w["session_id"].to_s.empty? }
    end

    status, started = invoke(:post, "/orchestrations/:id/start", params: { id: orch_id })
    assert_equal 200, status
    assert_equal @entry_id, started["orchestrator_session_id"]
    assert_equal "running", started["status"]
    refute_equal @workspace, @http.registry.get(@entry_id)[:agent].working_dir
    assert_equal "astock-research", @http.registry.get(@entry_id)[:agent].agent_profile.name
    assert_equal "投研总控｜600519/全流程协调", @http.registry.get(@entry_id)[:agent].name

    leader_rules = File.read(File.join(started["orchestrator_dir"], ".clackyrules"))
    assert_includes leader_rules, "ASTOCK_RESEARCH_CONTEXT_V1"
    assert_includes leader_rules, "运行身份：leader"
    assert_includes leader_rules, "内部主席规则"
    refute_includes leader_rules, "新编排"

    generated = @http.registry.sessions.reject { |id, _| id == @entry_id }
    assert_equal 10, generated.size
    assert generated.values.all? { |s| s[:agent].agent_profile.name == "astock-research" }
    generated_names = generated.values.map { |s| s[:agent].name }
    assert generated_names.all? { |name| name.include?("｜600519/") }
    assert_includes generated_names, "市场技术分析师｜600519/01 技术面与量价分析"
    # Starting provisions every Worker session but spends only one model turn
    # on the controller; Workers remain idle until the Leader assigns them.
    assert_equal [@entry_id], @http.runs.map { |run| run[:id] }
    worker_dir = generated.values.first[:agent].working_dir
    worker_rules = File.read(File.join(worker_dir, ".clackyrules"))
    assert_includes worker_rules, "运行身份：worker"
    assert_includes worker_rules, "内部委员规则"

    detail = invoke(:get, "/orchestrations/:id", params: { id: orch_id })[1]
    poll = invoke(:get, "/orchestrations/:id/poll", params: { id: orch_id })[1]
    assert_equal 10, detail["workers"].size
    assert_equal orch_id, poll["id"]

    worker = started["workers"].first
    task = started["tasks"].find { |t| t["assigned_to"] == worker["id"] }
    assert_equal 200, invoke(:post, "/orchestrations/:id/progress",
      params: { id: orch_id }, body: { "worker_id" => worker["id"], "task" => "阶段 1 · #{task["name"]}", "status" => "running" })[0]
    after_progress = invoke(:get, "/orchestrations/:id", params: { id: orch_id })[1]
    assert_equal started["tasks"].size, after_progress["tasks"].size
    assert_equal task["name"], after_progress["workers"].find { |w| w["id"] == worker["id"] }["current_task"]
    assert_equal 200, invoke(:post, "/orchestrations/:id/message",
      params: { id: orch_id }, body: { "worker_id" => worker["id"], "content" => "执行任务", "from" => "orchestrator" })[0]
    assert_equal 200, invoke(:post, "/orchestrations/:id/decision",
      params: { id: orch_id }, body: { "content" => "继续观察" })[0]
    assert_equal 200, invoke(:post, "/orchestrations/:id/progress",
      params: { id: orch_id }, body: { "worker_id" => worker["id"], "task" => task["name"], "status" => "done" })[0]

    add_status, added = invoke(:post, "/orchestrations/:id/workers",
      params: { id: orch_id }, body: { "role" => "测试审阅员", "prompt" => "只做接口测试" })
    assert_equal 200, add_status
    refute_empty added["session_id"]
    assert_equal "测试审阅员｜600519/只做接口测试",
      @http.registry.get(added["session_id"])[:agent].name

    assert_equal 200, invoke(:patch, "/orchestrations/:id/workers/:wid",
      params: { id: orch_id, wid: added["id"] }, body: { "model_id" => "fake-model" })[0]
    assert_equal 200, invoke(:post, "/orchestrations/:id/workers/:wid/restore_session",
      params: { id: orch_id, wid: added["id"] }, body: {})[0]
    rebuild_status, rebuilt = invoke(:post, "/orchestrations/:id/workers/:wid/rebuild_session",
      params: { id: orch_id, wid: added["id"] }, body: {})
    assert_equal 200, rebuild_status
    assert_equal "测试审阅员｜600519/只做接口测试",
      @http.registry.get(rebuilt["session_id"])[:agent].name
    assert_equal 200, invoke(:delete, "/orchestrations/:id/workers/:wid",
      params: { id: orch_id, wid: added["id"] })[0]

    assert_equal 403, invoke(:post, "/orchestrations/:id/stop", params: { id: orch_id },
      headers: { "x-caller" => ["orchestrator"] })[0]
    assert_equal 200, invoke(:post, "/orchestrations/:id/stop", params: { id: orch_id })[0]

    delete_status, deleted = invoke(:delete, "/orchestrations/:id", params: { id: orch_id })
    assert_equal 200, delete_status
    assert_equal @entry_id, deleted["entry_session_preserved"]
    refute_includes deleted["sessions_deleted"], @entry_id
    assert @http.registry.exist?(@entry_id)
    assert_equal @workspace, @http.registry.get(@entry_id)[:agent].working_dir
    assert_empty JSON.parse(File.read(AstockResearch::DataStore::DATA_FILE))["orchestrations"]
  end

  def test_message_summary_scrubs_invalid_utf8
    invalid = "【来自主席】任务：技术面分析".dup
    invalid << 0xFF
    invalid.force_encoding(Encoding::UTF_8)
    summary = AstockResearchExt.allocate.send(:msg_summary, invalid)
    assert summary.valid_encoding?
    assert_includes summary, "任务：技术面分析"
  end

  def test_research_concurrency_limit_blocks_extra_progress_and_dispatch
    body = valid_research.merge(
      "analysts" => %w[market social news],
      "max_concurrency" => 2
    )
    create_status, orch = invoke(:post, "/researches", body: body)
    assert_equal 200, create_status
    orch_id = orch["id"]
    assert_equal 2, orch.dig("research", "max_concurrency")
    assert_equal 200, invoke(:post, "/orchestrations/:id/start", params: { id: orch_id })[0]

    stage_one = orch["tasks"].select { |task| task["stage"] == 1 }
    stage_one.first(2).each do |task|
      assert_equal 200, invoke(:post, "/orchestrations/:id/progress",
        params: { id: orch_id },
        body: { "worker_id" => task["assigned_to"], "task" => task["name"], "status" => "running" })[0]
      assert_equal 200, invoke(:post, "/orchestrations/:id/message",
        params: { id: orch_id },
        body: { "worker_id" => task["assigned_to"], "content" => "执行 #{task["name"]}", "from" => "orchestrator" })[0]
    end

    blocked = stage_one.fetch(2)
    progress_status, progress_body = invoke(:post, "/orchestrations/:id/progress",
      params: { id: orch_id },
      body: { "worker_id" => blocked["assigned_to"], "task" => blocked["name"], "status" => "running" })
    assert_equal 429, progress_status
    assert_equal 2, progress_body["max_concurrency"]
    assert_equal 2, progress_body["running_tasks"]

    # Even if a Leader ignores the 429 response, /message refuses to wake a
    # Worker that does not own a successfully reserved running task.
    assert_equal 409, invoke(:post, "/orchestrations/:id/message",
      params: { id: orch_id },
      body: { "worker_id" => blocked["assigned_to"], "content" => "错误的超额派活", "from" => "orchestrator" })[0]
    assert_equal 3, @http.runs.size # one Leader kickoff + two Worker dispatches
  end

  def test_poll_watchdog_resumes_idle_worker_with_running_task
    orch = create_research
    orch_id = orch["id"]
    start_status, started = invoke(:post, "/orchestrations/:id/start", params: { id: orch_id })
    assert_equal 200, start_status
    task = started["tasks"].find { |candidate| candidate["stage"] == 1 }
    worker = started["workers"].find { |candidate| candidate["id"] == task["assigned_to"] }
    assert_equal 200, invoke(:post, "/orchestrations/:id/progress",
      params: { id: orch_id },
      body: { "worker_id" => worker["id"], "task" => task["name"], "status" => "running" })[0]

    persisted = JSON.parse(File.read(AstockResearch::DataStore::DATA_FILE))
    stored_task = persisted.dig("orchestrations", orch_id, "tasks").find { |candidate| candidate["id"] == task["id"] }
    stored_task["idle_detected_at"] = (Time.now - 60).iso8601
    File.write(AstockResearch::DataStore::DATA_FILE, JSON.pretty_generate(persisted))

    poll_status, poll = invoke(:get, "/orchestrations/:id/poll", params: { id: orch_id })
    assert_equal 200, poll_status
    assert_equal "running", poll["tasks"].find { |candidate| candidate["id"] == task["id"] }["status"]
    assert_equal worker["session_id"], @http.runs.last[:id]
    assert_includes @http.runs.last[:prompt], "系统自动续跑"
    assert_includes @http.runs.last[:prompt], "任务已完成"

    saved = JSON.parse(File.read(AstockResearch::DataStore::DATA_FILE))
    resumed = saved.dig("orchestrations", orch_id, "tasks").find { |candidate| candidate["id"] == task["id"] }
    assert_equal 1, resumed["auto_resume_count"]
    assert saved.dig("orchestrations", orch_id, "decision_log").any? { |entry| entry["action"] == "task_auto_resume" }

    # The cap must remain visible across later idle polls; it must not be
    # mistaken for a provider error that healed merely because the session is idle.
    resumed["auto_resume_count"] = 3
    resumed["idle_detected_at"] = (Time.now - 60).iso8601
    resumed.delete("auto_resume_exhausted_at")
    File.write(AstockResearch::DataStore::DATA_FILE, JSON.pretty_generate(saved))
    assert_equal 200, invoke(:get, "/orchestrations/:id/poll", params: { id: orch_id })[0]
    later_poll = invoke(:get, "/orchestrations/:id/poll", params: { id: orch_id })[1]
    stalled_worker = later_poll["workers"].find { |candidate| candidate["id"] == worker["id"] }
    assert_equal "awaiting_user", stalled_worker["error_state"]
    assert_equal "idle_resume_exhausted", stalled_worker["error_code"]
  end

  def test_worker_completion_accidentally_sent_to_self_is_rerouted_to_leader
    orch = create_research
    orch_id = orch["id"]
    start_status, started = invoke(:post, "/orchestrations/:id/start", params: { id: orch_id })
    assert_equal 200, start_status
    task = started["tasks"].find { |candidate| candidate["stage"] == 1 }
    worker = started["workers"].find { |candidate| candidate["id"] == task["assigned_to"] }
    assert_equal 200, invoke(:post, "/orchestrations/:id/progress",
      params: { id: orch_id },
      body: { "worker_id" => worker["id"], "task" => task["name"], "status" => "running" })[0]

    # This is the exact malformed payload observed in the live 002230 run:
    # sender and target are both the same Worker even though it is a completion report.
    assert_equal 200, invoke(:post, "/orchestrations/:id/message",
      params: { id: orch_id },
      body: {
        "worker_id" => worker["id"], "from" => worker["id"], "from_role" => worker["role"],
        "content" => "任务已完成。报告已写入 REPORT.md。"
      })[0]

    detail = invoke(:get, "/orchestrations/:id", params: { id: orch_id })[1]
    assert_equal "done", detail["tasks"].find { |candidate| candidate["id"] == task["id"] }["status"]
    assert_equal @entry_id, @http.runs.last[:id]
    report_log = detail["decision_log"].reverse.find { |entry| entry["type"] == "report" }
    assert_equal "汇报 → Leader", report_log["detail"]
  end
end

if $PROGRAM_NAME == __FILE__
  methods = AstockResearchApiIntegrationTest.instance_methods(false).grep(/^test_/).sort
  failures = []
  methods.each do |name|
    test = AstockResearchApiIntegrationTest.new
    begin
      test.setup
      test.public_send(name)
      puts "PASS #{name}"
    rescue => e
      failures << [name, e]
      warn "FAIL #{name}: #{e.class}: #{e.message}"
      warn e.backtrace.first(8).join("\n")
    end
  end
  puts "#{methods.size - failures.size}/#{methods.size} tests passed"
  exit(failures.empty? ? 0 : 1)
end
