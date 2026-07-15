# ── Decision log + message helpers ────────────────────────────────────────
# `decision_log` is a bounded (last 200) array of {at, actor, action, detail,
# type?, summary?, target?} entries per orchestration. The frontend renders
# it as a filterable feed. `msg_summary` extracts a one-line preview from
# a worker's raw message, stripping the Worker sender prefix.
module AstockResearch
  module Log
    # Append one decision-log entry.
    # `detail` is the fallback raw string for old clients or missing i18n keys.
    # `code` + `params`, both passed through opts, let the frontend render via
    # the i18n dictionary first and fall back to detail when no translation is
    # available. This makes templated events language-neutral, while AI-produced
    # summaries stay in the AI's original language.
    def append_log(orch, actor, action, detail, opts = {})
      orch["decision_log"] ||= []
      entry = {
        "at"     => Time.now.iso8601,
        "actor"  => actor,
        "action" => action,
        "detail" => detail
      }
      entry["type"]    = opts[:type]    if opts[:type]
      entry["summary"] = opts[:summary] if opts[:summary] && !opts[:summary].to_s.strip.empty?
      entry["target"]  = opts[:target]  if opts[:target]
      entry["code"]    = opts[:code]    if opts[:code]
      entry["params"]  = opts[:params]  if opts[:params].is_a?(Hash) && !opts[:params].empty?
      orch["decision_log"] << entry
      orch["decision_log"] = orch["decision_log"].last(200)
    end

    # Extract a one-sentence summary from a Worker message:
    # Worker messages reserve the first line for the sender prefix, so use the
    # first non-empty line after that prefix. Leader/user messages do not have
    # this prefix, so use the first non-empty line directly. Sentence boundaries
    # are punctuation or a newline.
    def msg_summary(content)
      # Model-authored curl scripts may produce a request string tagged as
      # UTF-8 with a stray invalid byte. Scrub before applying Unicode regexps
      # so logging cannot turn a delivered assignment into a session error.
      text = utf8_text(content)
      text.sub!(/\A【[^】]*】\s*/, "")
      line = text.split(/\r?\n/).map(&:strip).find { |l| !l.empty? } || ""
      if (m = line.match(/\A(.+?[。！？.!?])/))
        line = m[1]
      end
      line
    end

    def utf8_text(value)
      value.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # If stopped, freeze at stopped_at; otherwise count live.
    def elapsed_seconds(orch)
      return 0 unless orch["started_at"]
      end_time = orch["stopped_at"] ? Time.parse(orch["stopped_at"]) : Time.now
      (end_time - Time.parse(orch["started_at"])).to_i
    rescue
      0
    end
  end
end
