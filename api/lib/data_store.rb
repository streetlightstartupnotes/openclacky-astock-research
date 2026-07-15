# ── Data store — orchestrations.json load/save ─────────────────────────────
# Persists all orchestrations to a single JSON file under the extension's data/
# dir. Callers treat this as the source of truth; state mutations are always
# followed by `save_data(data)`.
module AstockResearch
  module DataStore
    DATA_ROOT = File.expand_path(
      ENV.fetch("ASTOCK_DATA_DIR", File.join(Dir.home, ".clacky", "ext", "data", "astock-research"))
    )
    DATA_FILE = File.join(DATA_ROOT, "orchestrations.json")
    # openclacky uuid pattern — used to detect legacy model_id values that
    # need migrating to model **names** (stable across process restarts).
    UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    def load_data
      FileUtils.mkdir_p(File.dirname(DATA_FILE))
      return { "orchestrations" => {}, "active_id" => nil } unless File.exist?(DATA_FILE)
      data = JSON.parse(File.read(DATA_FILE))
      migrate_worker_model_refs!(data)
      data
    end

    def save_data(data)
      File.write(DATA_FILE, JSON.pretty_generate(data))
    end

    # One-time migration: legacy worker records store an openclacky uuid in
    # model_id. Since uuids regenerate every process start, translate them
    # to the stable model **name** while the current catalog still holds
    # the id. Orphan uuids (already invalidated by a prior restart) can't
    # be recovered — nil them out and let UI show the default label.
    private def migrate_worker_model_refs!(data)
      models = (agent_config&.models || [])
      return if models.empty?
      dirty = false
      (data["orchestrations"] || {}).each_value do |orch|
        (orch["workers"] || []).each do |w|
          mid = w["model_id"]
          next if mid.nil? || mid.to_s.empty?
          next unless mid.to_s =~ UUID_RE
          hit = models.find { |m| m["id"] == mid }
          if hit
            w["model_id"] = hit["model"].to_s
            dirty = true
            logger.info("[astock-research][migrate] worker #{w["id"]} model_id #{mid[0,8]}… → #{hit["model"]}")
          else
            # legacy uuid no longer in catalog — irrecoverable, clear so the
            # UI stops showing a broken selection.
            w["model_id"] = nil
            dirty = true
            logger.warn("[astock-research][migrate] worker #{w["id"]} orphan uuid #{mid[0,8]}… → cleared")
          end
        end
      end
      save_data(data) if dirty
    rescue => e
      logger.warn("[astock-research][migrate] failed: #{e.class}: #{e.message}")
    end
  end
end
