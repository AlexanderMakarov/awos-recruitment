#!/usr/bin/env bash
# Tests for scan.sh — the deterministic discovery+dedup scanner of the gh-watch-reviews skill.
# Self-contained: fakes `gh` via a PATH shim; needs only bash + jq.
# Run: bash scan_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/scan.sh"

PASS=0
FAIL=0

# ---------- harness ----------

setup() {
  SANDBOX="$(mktemp -d)"
  export FAKE_GH_DIR="$SANDBOX/fake-gh"
  mkdir -p "$FAKE_GH_DIR"
  STATE="$SANDBOX/gh-watch-reviews.local.json"
  LOG="$SANDBOX/watch.log"

  # fake gh: dispatches on argv, reads canned responses from FAKE_GH_DIR
  cat > "$SANDBOX/gh" <<'FAKE'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"auth status"*)
    exit "${FAKE_GH_AUTH_EXIT:-0}"
    ;;
  *"--review-requested=@me"*)
    if [ -n "${FAKE_GH_REQUESTED_EXIT:-}" ]; then exit "$FAKE_GH_REQUESTED_EXIT"; fi
    cat "$FAKE_GH_DIR/requested.json" 2>/dev/null || echo "[]"
    ;;
  *"search prs"*)
    if [ -n "${FAKE_GH_UNREQUESTED_EXIT:-}" ]; then exit "$FAKE_GH_UNREQUESTED_EXIT"; fi
    cat "$FAKE_GH_DIR/unrequested.json" 2>/dev/null || echo "[]"
    ;;
  *"api user"*)
    echo "${FAKE_GH_LOGIN:-me}"
    ;;
  *"pr view"*"headRefOid"*)
    # gh pr view <n> --repo <r> --json headRefOid
    n="$3"
    cat "$FAKE_GH_DIR/head-$n.json" 2>/dev/null || { echo "no such pr" >&2; exit 1; }
    ;;
  *"pr view"*"reviews"*)
    # gh pr view <n> --repo <r> --json state,reviews
    n="$3"
    cat "$FAKE_GH_DIR/reviews-$n.json" 2>/dev/null || echo '{"state": "OPEN", "reviews": []}'
    ;;
  *)
    echo "fake gh: unexpected args: $args" >&2
    exit 64
    ;;
esac
FAKE
  chmod +x "$SANDBOX/gh"
  export PATH="$SANDBOX:$PATH"

  # default fixtures: empty world, default config
  echo "[]" > "$FAKE_GH_DIR/requested.json"
  echo "[]" > "$FAKE_GH_DIR/unrequested.json"
  write_state '{}'
}

teardown() {
  rm -rf "$SANDBOX"
  unset FAKE_GH_AUTH_EXIT FAKE_GH_REQUESTED_EXIT FAKE_GH_UNREQUESTED_EXIT 2>/dev/null || true
}

# write_state '<state-object-json>' [config-overrides-json]
write_state() {
  local state="$1" overrides="${2:-null}"
  [ "$overrides" = "null" ] && overrides='{}'
  jq -n --argjson state "$state" --argjson ov "$overrides" \
    '{config: ({exclude_bots: true, exclude_authors: [], include_drafts: false, watch_unrequested: true} + $ov), state: $state}' \
    > "$STATE"
}

# pr <number> <title> <author> [is_bot] [isDraft] [createdAt]
pr() {
  jq -n --argjson n "$1" --arg t "$2" --arg a "$3" \
    --argjson bot "${4:-false}" --argjson draft "${5:-false}" --arg c "${6:-2026-07-01T00:00:00Z}" \
    '{number: $n, title: $t, author: {login: $a, is_bot: $bot}, url: ("https://github.com/o/r/pull/" + ($n|tostring)), isDraft: $draft, createdAt: $c}'
}

run_once() {
  OUT="$("$SCAN" --repo o/r --state "$STATE" --once "$@" 2>"$SANDBOX/stderr")"
  RC=$?
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $CASE — $1"
    echo "  expected: $2"
    echo "  actual:   $3"
  fi
}

jqout() { echo "$OUT" | jq -r "$1"; }

# ---------- cases ----------

CASE="empty scan → status empty, rc 0"
setup
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "empty" "$(jqout .status)"
assert_eq "checked_at present" "yes" "$(echo "$OUT" | jq -r 'if (.checked_at | length) > 8 then "yes" else "no" end')"
teardown

CASE="new unrequested PR surfaces as never reviewed"
setup
pr 5 "Add thing" alice | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "candidates" "$(jqout .status)"
assert_eq "count" 1 "$(jqout '.candidates | length')"
assert_eq "why" "never reviewed" "$(jqout .candidates[0].why)"
assert_eq "author flattened" "alice" "$(jqout .candidates[0].author)"
teardown

CASE="requested query wins the why when PR matches both"
setup
pr 6 "Fix bug" bob | jq -s . > "$FAKE_GH_DIR/requested.json"
pr 6 "Fix bug" bob | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "count (union, not duplicate)" 1 "$(jqout '.candidates | length')"
assert_eq "why" "review requested" "$(jqout .candidates[0].why)"
teardown

CASE="bot PRs suppressed when exclude_bots"
setup
pr 7 "Bump dep" "dependabot" true | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "status" "empty" "$(jqout .status)"
teardown

CASE="bot PRs kept when exclude_bots false"
setup
write_state '{}' '{"exclude_bots": false}'
pr 7 "Bump dep" "dependabot" true | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "status" "candidates" "$(jqout .status)"
teardown

CASE="excluded author suppressed (config + ad-hoc flag)"
setup
write_state '{}' '{"exclude_authors": ["carol"]}'
{ pr 8 "A" carol; pr 9 "B" dave; } | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "config exclude" "9" "$(jqout '.candidates | map(.number) | join(",")')"
run_once --exclude dave
assert_eq "ad-hoc exclude" "empty" "$(jqout .status)"
teardown

CASE="drafts suppressed unless include_drafts"
setup
pr 10 "WIP" erin false true | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "draft suppressed" "empty" "$(jqout .status)"
run_once --include-drafts
assert_eq "draft included via flag" "candidates" "$(jqout .status)"
teardown

CASE="watch_unrequested false → unrequested query not used"
setup
write_state '{}' '{"watch_unrequested": false}'
pr 11 "Sneaky" frank | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "status" "empty" "$(jqout .status)"
teardown

CASE="reviewed PR suppressed on unrequested match, surfaces on re-request"
setup
write_state '{"12": {"sha": "aaa", "decision": "reviewed", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
pr 12 "Round 2" gina | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "suppressed on unrequested" "empty" "$(jqout .status)"
pr 12 "Round 2" gina | jq -s . > "$FAKE_GH_DIR/requested.json"
run_once
assert_eq "surfaces on requested" "candidates" "$(jqout .status)"
assert_eq "why" "re-requested after your review" "$(jqout .candidates[0].why)"
teardown

CASE="sticky skip: unrequested match never resurfaces"
setup
write_state '{"13": {"sha": "aaa", "decision": "skipped", "via": "unrequested", "at": "2026-07-01T00:00:00Z"}}'
pr 13 "Skipped once" hank | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "status" "empty" "$(jqout .status)"
teardown

CASE="skip via unrequested + requested match → surfaces as previously skipped"
setup
write_state '{"14": {"sha": "aaa", "decision": "skipped", "via": "unrequested", "at": "2026-07-01T00:00:00Z"}}'
pr 14 "Now requested" iris | jq -s . > "$FAKE_GH_DIR/requested.json"
run_once
assert_eq "status" "candidates" "$(jqout .status)"
assert_eq "why" "review requested — previously skipped" "$(jqout .candidates[0].why)"
teardown

CASE="skip via requested: same head sha stays suppressed, new sha surfaces"
setup
write_state '{"15": {"sha": "aaa", "decision": "skipped", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
pr 15 "Declined request" jude | jq -s . > "$FAKE_GH_DIR/requested.json"
echo '{"headRefOid": "aaa"}' > "$FAKE_GH_DIR/head-15.json"
run_once
assert_eq "same sha suppressed" "empty" "$(jqout .status)"
echo '{"headRefOid": "bbb"}' > "$FAKE_GH_DIR/head-15.json"
run_once
assert_eq "new sha surfaces" "candidates" "$(jqout .status)"
assert_eq "why" "new commits since your last decision" "$(jqout .candidates[0].why)"
teardown

CASE="fresh in_progress → whole tick short-circuits to in_review"
setup
write_state "{\"16\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
{ pr 16 "Being reviewed" kate; pr 17 "Fresh" liam; } | jq -s . > "$FAKE_GH_DIR/requested.json"
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "in_review" "$(jqout .status)"
assert_eq "no candidates leak" "null" "$(jqout .candidates)"
teardown

CASE="stale in_progress (>2h) → status stale_in_progress with PR numbers"
setup
write_state '{"16": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "stale_in_progress" "$(jqout .status)"
assert_eq "prs" "16" "$(jqout '.prs | join(",")')"
teardown

CASE="watch mode: stale in_progress exits 4"
setup
write_state '{"16": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
OUT="$("$SCAN" --repo o/r --state "$STATE" --interval 1 --ttl 30 --log "$LOG" 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 4 "$RC"
assert_eq "status" "stale_in_progress" "$(jqout .status)"
teardown

CASE="watch mode: fresh in_progress pauses polling but still expires on ttl"
setup
write_state "{\"16\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
pr 17 "Would surface" liam | jq -s . > "$FAKE_GH_DIR/requested.json"
OUT="$("$SCAN" --repo o/r --state "$STATE" --interval 1 --ttl 2 --log "$LOG" 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 3 "$RC"
assert_eq "status" "expired" "$(jqout .status)"
teardown

CASE="in_progress resolved from GitHub: viewer review submitted after at → flipped to reviewed, scan proceeds"
setup
write_state '{"18": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
echo '{"state": "OPEN", "reviews": [{"author": {"login": "me"}, "state": "COMMENTED", "submittedAt": "2026-07-02T00:00:00Z"}]}' > "$FAKE_GH_DIR/reviews-18.json"
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "empty" "$(jqout .status)"
assert_eq "state flipped" "reviewed" "$(jq -r '.state["18"].decision' "$STATE")"
assert_eq "sha preserved" "aaa" "$(jq -r '.state["18"].sha' "$STATE")"
teardown

CASE="in_progress NOT resolved by a review predating at"
setup
write_state "{\"18\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
echo '{"state": "OPEN", "reviews": [{"author": {"login": "me"}, "state": "APPROVED", "submittedAt": "2020-01-01T00:00:00Z"}]}' > "$FAKE_GH_DIR/reviews-18.json"
run_once
assert_eq "status" "in_review" "$(jqout .status)"
assert_eq "state untouched" "in_progress" "$(jq -r '.state["18"].decision' "$STATE")"
teardown

CASE="in_progress NOT resolved by someone else's review"
setup
write_state "{\"18\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
echo '{"state": "OPEN", "reviews": [{"author": {"login": "someone-else"}, "state": "APPROVED", "submittedAt": "2099-01-01T00:00:00Z"}]}' > "$FAKE_GH_DIR/reviews-18.json"
run_once
assert_eq "status" "in_review" "$(jqout .status)"
teardown

CASE="in_progress on a merged PR → entry pruned, scan proceeds"
setup
write_state "{\"19\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
echo '{"state": "MERGED", "reviews": []}' > "$FAKE_GH_DIR/reviews-19.json"
run_once
assert_eq "rc" 0 "$RC"
assert_eq "status" "empty" "$(jqout .status)"
assert_eq "entry pruned" "null" "$(jq -r '.state["19"] // "null"' "$STATE")"
teardown

CASE="stale in_progress with a submitted review resolves instead of nagging"
setup
write_state '{"18": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
echo '{"state": "OPEN", "reviews": [{"author": {"login": "me"}, "state": "CHANGES_REQUESTED", "submittedAt": "2026-07-01T05:00:00Z"}]}' > "$FAKE_GH_DIR/reviews-18.json"
run_once
assert_eq "status" "empty" "$(jqout .status)"
assert_eq "state flipped" "reviewed" "$(jq -r '.state["18"].decision' "$STATE")"
teardown

CASE="unparseable at on in_progress counts as stale (fail visible, not hidden)"
setup
write_state '{"18": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-28 17:24:21 +0400"}}'
run_once
assert_eq "status" "stale_in_progress" "$(jqout .status)"
teardown

CASE="unresolvable stale in_progress still reported"
setup
write_state '{"18": {"sha": "aaa", "decision": "in_progress", "via": "requested", "at": "2026-07-01T00:00:00Z"}}'
run_once
assert_eq "status" "stale_in_progress" "$(jqout .status)"
teardown

CASE="candidates sorted oldest-first by createdAt"
setup
{ pr 20 "Newer" mia false false "2026-07-10T00:00:00Z"; pr 21 "Older" noah false false "2026-07-02T00:00:00Z"; } | jq -s . > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "order" "21,20" "$(jqout '.candidates | map(.number) | join(",")')"
teardown

CASE="malformed search output → status error, rc 1"
setup
echo "API rate limit exceeded" > "$FAKE_GH_DIR/unrequested.json"
run_once
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
teardown

CASE="failed search (nonzero gh exit) → status error, rc 1"
setup
export FAKE_GH_REQUESTED_EXIT=1
run_once
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
teardown

CASE="unauthenticated gh → status error, rc 1"
setup
export FAKE_GH_AUTH_EXIT=1
run_once
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
assert_eq "message mentions auth" "yes" "$(echo "$OUT" | jq -r 'if (.message | test("auth")) then "yes" else "no" end')"
teardown

CASE="missing state file → status error, rc 1"
setup
rm "$STATE"
run_once
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
teardown

CASE="watch mode: quiet polls heartbeat to log, exits 3 on ttl"
setup
OUT="$("$SCAN" --repo o/r --state "$STATE" --interval 1 --ttl 2 --log "$LOG" 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 3 "$RC"
assert_eq "status" "expired" "$(jqout .status)"
assert_eq "heartbeat lines written" "yes" "$([ -s "$LOG" ] && grep -q "no PRs need your review" "$LOG" && echo yes || echo no)"
teardown

CASE="watch mode: no --ttl → still alive well past a short wait (runs until something happens)"
setup
"$SCAN" --repo o/r --state "$STATE" --interval 1 --log "$LOG" &
WPID=$!
sleep 3
if kill -0 "$WPID" 2>/dev/null; then alive=yes; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; else alive=no; fi
assert_eq "watcher still running" "yes" "$alive"
teardown

CASE="watch mode: orphaned watcher exits on its own"
setup
bash -c "\"$SCAN\" --repo o/r --state \"$STATE\" --interval 1 --log \"$LOG\" >/dev/null 2>&1 & echo \$!" > "$SANDBOX/wpid"
WPID="$(cat "$SANDBOX/wpid")"
sleep 4
if kill -0 "$WPID" 2>/dev/null; then alive=yes; kill "$WPID" 2>/dev/null; else alive=no; fi
assert_eq "watcher gone after parent died" "no" "$alive"
teardown

CASE="watch mode: exits 0 with candidates when a PR appears"
setup
pr 30 "Appeared" olga | jq -s . > "$FAKE_GH_DIR/requested.json"
OUT="$("$SCAN" --repo o/r --state "$STATE" --interval 1 --ttl 30 --log "$LOG" 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 0 "$RC"
assert_eq "status" "candidates" "$(jqout .status)"
teardown

CASE="watch mode: search failure exits 1 immediately (no silent success)"
setup
echo "garbage" > "$FAKE_GH_DIR/unrequested.json"
OUT="$("$SCAN" --repo o/r --state "$STATE" --interval 1 --ttl 30 --log "$LOG" 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
teardown

# ---------- summary ----------

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
