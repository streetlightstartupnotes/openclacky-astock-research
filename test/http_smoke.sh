#!/usr/bin/env bash
set -euo pipefail

BASE="${OPENCLACKY_URL:-http://127.0.0.1:7070}"
TMP="$(mktemp -d)"
WORK_DIR="$TMP/entry-workspace"
SID=""
ORCH_ID=""

cleanup() {
  if [[ -n "$ORCH_ID" ]]; then
    curl -fsS -X DELETE "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SID" ]]; then
    curl -fsS -X DELETE "$BASE/api/sessions/$SID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

session_body="$(ruby -rjson -e 'puts JSON.generate({name:"astock-http-smoke", agent_profile:"astock-research", source:"manual", working_dir:ARGV[0]})' "$WORK_DIR")"
session_json="$(curl -fsS -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d "$session_body")"
SID="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("session").fetch("id")' <<<"$session_json")"

bad_body="$(ruby -rjson -e 'puts JSON.generate({ticker:"600519",trade_date:"not-a-date",analysts:["market"],entry_session_id:ARGV[0]})' "$SID")"
bad_code="$(curl -sS -o "$TMP/bad.json" -w '%{http_code}' -X POST "$BASE/api/ext/astock-research/researches" -H 'Content-Type: application/json' -d "$bad_body")"
[[ "$bad_code" == "422" ]]

create_body="$(ruby -rjson -e 'puts JSON.generate({ticker:"600519",trade_date:"2026-07-15",analysts:["market"],risk_profile:"balanced",entry_session_id:ARGV[0],name:"HTTP smoke research"})' "$SID")"
orch_json="$(curl -fsS -X POST "$BASE/api/ext/astock-research/researches" -H 'Content-Type: application/json' -d "$create_body")"
ORCH_ID="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")' <<<"$orch_json")"

curl -fsS "$BASE/api/ext/astock-research/orchestrations?session_id=$SID" |
  ruby -rjson -e 'd=JSON.parse(STDIN.read); abort "filtered list mismatch" unless d.fetch("orchestrations").size==1 && d.fetch("orchestrations")[0].fetch("id")==ARGV[0]' "$ORCH_ID"
curl -fsS "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID" |
  ruby -rjson -e 'd=JSON.parse(STDIN.read); abort "detail mismatch" unless d.fetch("entry_session_id")==ARGV[0] && d.fetch("workers").size==10' "$SID"
curl -fsS "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/poll" |
  ruby -rjson -e 'd=JSON.parse(STDIN.read); abort "poll mismatch" unless d.fetch("status")=="idle" && d.fetch("orchestrator_session_id")==ARGV[0]' "$SID"

curl -fsS -X POST "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/decision" -H 'Content-Type: application/json' -d '{"content":"HTTP smoke decision"}' >/dev/null

worker_json="$(curl -fsS -X POST "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/workers" -H 'Content-Type: application/json' -d '{"role":"HTTP smoke reviewer","prompt":"API validation only"}')"
WID="$(ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("id")' <<<"$worker_json")"
curl -fsS -X PATCH "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/workers/$WID" -H 'Content-Type: application/json' -d '{"model_id":""}' >/dev/null
curl -fsS -X POST "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/workers/$WID/rebuild_session" -H 'Content-Type: application/json' -d '{}' |
  ruby -rjson -e 'd=JSON.parse(STDIN.read); abort "expected deferred rebuild" unless d["deferred"]==true && d["status"]=="rebuild_pending"'
curl -fsS -X DELETE "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID/workers/$WID" >/dev/null

delete_json="$(curl -fsS -X DELETE "$BASE/api/ext/astock-research/orchestrations/$ORCH_ID")"
ruby -rjson -e 'd=JSON.parse(STDIN.read); abort "entry was not preserved" unless d["entry_session_preserved"]==ARGV[0]; abort "entry directory not restored" unless d["entry_working_dir_restored"]==ARGV[1]' "$SID" "$WORK_DIR" <<<"$delete_json"
ORCH_ID=""

curl -fsS "$BASE/api/sessions/$SID" |
  ruby -rjson -e 'd=JSON.parse(STDIN.read).fetch("session"); abort "session profile changed" unless d["agent_profile"]=="astock-research"; abort "working dir changed" unless d["working_dir"]==ARGV[0]' "$WORK_DIR"

curl -fsS -X DELETE "$BASE/api/sessions/$SID" >/dev/null
SID=""
echo "PASS http_smoke: session-first CRUD, validation, filtering, worker lifecycle, preservation"
