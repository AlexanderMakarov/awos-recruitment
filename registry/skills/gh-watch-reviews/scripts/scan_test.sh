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
    if [ "${FAKE_GH_AUTH_EXIT:-0}" != 0 ]; then
      echo "${FAKE_GH_AUTH_STDERR:-You are not logged into any GitHub hosts. To log in, run: gh auth login}" >&2
      exit "$FAKE_GH_AUTH_EXIT"
    fi
    exit 0
    ;;
  *"--review-requested=@me"*)
    # A shared flag file lets a test make gh fail for the first N calls only,
    # which is how a transient outage actually behaves.
    if [ -n "${FAKE_GH_FAIL_UNTIL:-}" ] && [ -f "$FAKE_GH_FAIL_UNTIL" ]; then
      n=$(cat "$FAKE_GH_FAIL_UNTIL" 2>/dev/null || echo 0)
      if [ "$n" -gt 0 ]; then
        echo $((n - 1)) > "$FAKE_GH_FAIL_UNTIL"
        echo "error connecting to api.github.com" >&2
        echo "check your internet connection or https://githubstatus.com" >&2
        exit 1
      fi
    fi
    if [ -n "${FAKE_GH_REQUESTED_EXIT:-}" ]; then
      echo "${FAKE_GH_REQUESTED_STDERR:-error connecting to api.github.com}" >&2
      exit "$FAKE_GH_REQUESTED_EXIT"
    fi
    cat "$FAKE_GH_DIR/requested.json" 2>/dev/null || echo "[]"
    ;;
  *"search prs"*)
    if [ -n "${FAKE_GH_UNREQUESTED_EXIT:-}" ]; then exit "$FAKE_GH_UNREQUESTED_EXIT"; fi
    cat "$FAKE_GH_DIR/unrequested.json" 2>/dev/null || echo "[]"
    ;;
  *"repo view"*"nameWithOwner"*)
    if [ -n "${FAKE_GH_REPOVIEW_EXIT:-}" ]; then
      echo "${FAKE_GH_REPOVIEW_STDERR:-none of the git remotes configured for this repository point to a known GitHub host}" >&2
      exit "$FAKE_GH_REPOVIEW_EXIT"
    fi
    echo "${FAKE_GH_REPO:-o/r}"
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
  unset FAKE_GH_AUTH_EXIT FAKE_GH_AUTH_STDERR FAKE_GH_REQUESTED_EXIT \
        FAKE_GH_REQUESTED_STDERR FAKE_GH_UNREQUESTED_EXIT FAKE_GH_FAIL_UNTIL \
        FAKE_GH_REPO FAKE_GH_REPOVIEW_EXIT FAKE_GH_REPOVIEW_STDERR 2>/dev/null || true
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
assert_eq "terminal errors say so explicitly" "false" "$(jqout .retryable)"
teardown

CASE="every error carries retryable — a caller never has to guess a missing field"
setup
rm "$STATE"
run_once
assert_eq "missing state file" "false" "$(jqout .retryable)"
teardown
setup
OUT="$("$SCAN" --repo o/r --state "$STATE" --once --bogus-flag 2>/dev/null)"
assert_eq "unknown argument" "false" "$(echo "$OUT" | jq -r .retryable)"
teardown

CASE="an auth check that fails only because the network is down is not an auth error"
setup
export FAKE_GH_AUTH_EXIT=1 FAKE_GH_AUTH_STDERR="error connecting to api.github.com"
run_once
assert_eq "not reported as an auth problem" "no" \
  "$(echo "$OUT" | jq -r 'if (.message // "" | test("not authenticated")) then "yes" else "no" end')"
teardown

CASE="--once reports whether an error is worth retrying"
setup
export FAKE_GH_REQUESTED_EXIT=1 FAKE_GH_REQUESTED_STDERR="error connecting to api.github.com"
run_once
assert_eq "rc" 1 "$RC"
assert_eq "retryable" "true" "$(jqout .retryable)"
unset FAKE_GH_REQUESTED_STDERR
export FAKE_GH_REQUESTED_EXIT=1 FAKE_GH_REQUESTED_STDERR="HTTP 401: Bad credentials"
run_once
assert_eq "auth error is not retryable" "false" "$(jqout .retryable)"
teardown

# ---------- how long a review may hold the in-flight lock ----------

# Ages are always computed from now — never a literal date, which silently
# drifts across a threshold as the calendar moves and turns a passing test into
# a failing one overnight.
# 90 min in: inside the 2h default, outside a 1h setting.
at_90min_ago() { jq -rn --argjson t "$(( $(date -u +%s) - 5400 ))" '$t | todate'; }
at_days_ago() { jq -rn --argjson t "$(( $(date -u +%s) - ($1 * 86400) ))" '$t | todate'; }

CASE="stale threshold defaults to 2h when config says nothing"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}"
run_once
assert_eq "90min entry still just pauses" "in_review" "$(jqout .status)"
teardown

CASE="config.stale_review_hours shortens the threshold"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}" '{"stale_review_hours": 1}'
run_once
assert_eq "status" "stale_in_progress" "$(jqout .status)"
assert_eq "prs" "22" "$(jqout '.prs | join(",")')"
assert_eq "reports the threshold it used" "1" "$(jqout .held_for_over_hours)"
teardown

CASE="config.stale_review_hours lengthens the threshold"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_days_ago 10)\"}}" '{"stale_review_hours": 720}'
echo '{"state": "OPEN", "reviews": []}' > "$FAKE_GH_DIR/reviews-22.json"
run_once
assert_eq "10-day-old entry still inside a 30-day window" "in_review" "$(jqout .status)"
teardown

CASE="fractional hours accepted (0.5h = 30min)"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}" '{"stale_review_hours": 0.5}'
run_once
assert_eq "status" "stale_in_progress" "$(jqout .status)"
teardown

CASE="--stale-hours overrides config for one run, config unchanged"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}" '{"stale_review_hours": 8}'
run_once
assert_eq "config 8h → pauses" "in_review" "$(jqout .status)"
run_once --stale-hours 1
assert_eq "flag 1h → stale" "stale_in_progress" "$(jqout .status)"
assert_eq "config not rewritten" "8" "$(jq -r '.config.stale_review_hours' "$STATE")"
teardown

CASE="a nonsense threshold is an error, never a silently-ignored setting"
setup
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}" '{"stale_review_hours": "soon"}'
run_once
assert_eq "rc" 1 "$RC"
assert_eq "status" "error" "$(jqout .status)"
write_state "{\"22\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(at_90min_ago)\"}}" '{"stale_review_hours": 0}'
run_once
assert_eq "zero rejected" "error" "$(jqout .status)"
teardown

CASE="empty scan hands back a ready-to-print heartbeat line"
setup
run_once
assert_eq "line matches the heartbeat format verbatim" "gh-watch-reviews: o/r · no PRs need your review · checked $(jqout .checked_at)" "$(jqout .line)"
teardown

CASE="in_review hands back no line — a paused tick says nothing"
setup
write_state "{\"16\": {\"sha\": \"aaa\", \"decision\": \"in_progress\", \"via\": \"requested\", \"at\": \"$(date -u +%FT%TZ)\"}}"
run_once
assert_eq "status" "in_review" "$(jqout .status)"
assert_eq "no line" "null" "$(jqout .line)"
teardown

CASE="candidates hand back no line — the skill takes over, not a one-liner"
setup
pr 60 "Needs review" olga | jq -s . > "$FAKE_GH_DIR/requested.json"
run_once
assert_eq "status" "candidates" "$(jqout .status)"
assert_eq "no line" "null" "$(jqout .line)"
teardown

CASE="errors hand back a printable line too"
setup
export FAKE_GH_REQUESTED_EXIT=1
run_once
assert_eq "line present" "yes" "$(echo "$OUT" | jq -r 'if (.line | startswith("gh-watch-reviews: search failed")) then "yes" else "no" end')"
teardown
setup
rm "$STATE"
run_once
assert_eq "terminal errors too" "yes" "$(echo "$OUT" | jq -r 'if (.line | length) > 20 then "yes" else "no" end')"
teardown

# ---------- defaults: `scan.sh --once` with no other arguments ----------
#
# The recurring form embeds this command in a scheduled prompt. A prompt
# carrying absolute paths and an owner/repo cannot be shipped in a skill or
# moved between checkouts, so both arguments have to default.

CASE="--repo defaults to the repo gh resolves"
setup
export FAKE_GH_REPO="acme/widgets"
pr 70 "Needs review" olga | jq -s . > "$FAKE_GH_DIR/requested.json"
OUT="$("$SCAN" --state "$STATE" --once 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 0 "$RC"
assert_eq "scanned without --repo" "candidates" "$(jqout .status)"
teardown

CASE="--state defaults to .claude/gh-watch-reviews.local.json at the repo root"
setup
REPO_ROOT="$SANDBOX/repo"; mkdir -p "$REPO_ROOT/.claude" "$REPO_ROOT/deep/nested"
git -C "$REPO_ROOT" init -q 2>/dev/null
STATE="$REPO_ROOT/.claude/gh-watch-reviews.local.json"; write_state '{}'
pr 71 "Needs review" olga | jq -s . > "$FAKE_GH_DIR/requested.json"
OUT="$(cd "$REPO_ROOT/deep/nested" && "$SCAN" --repo o/r --once 2>"$SANDBOX/stderr")"
assert_eq "found the state file from a subdirectory" "candidates" "$(echo "$OUT" | jq -r .status)"
teardown

CASE="no arguments at all beyond --once"
setup
REPO_ROOT="$SANDBOX/repo"; mkdir -p "$REPO_ROOT/.claude"
git -C "$REPO_ROOT" init -q 2>/dev/null
STATE="$REPO_ROOT/.claude/gh-watch-reviews.local.json"; write_state '{}'
OUT="$(cd "$REPO_ROOT" && "$SCAN" --once 2>"$SANDBOX/stderr")"
assert_eq "status" "empty" "$(echo "$OUT" | jq -r .status)"
assert_eq "line names the resolved repo" "yes" "$(echo "$OUT" | jq -r 'if (.line | test("o/r")) then "yes" else "no" end')"
teardown

CASE="an unresolvable repo is an error naming the flag, and says whether retrying helps"
setup
export FAKE_GH_REPOVIEW_EXIT=1
OUT="$("$SCAN" --state "$STATE" --once 2>"$SANDBOX/stderr")"
RC=$?
assert_eq "rc" 1 "$RC"
assert_eq "message points at --repo" "yes" "$(echo "$OUT" | jq -r 'if (.message | test("--repo")) then "yes" else "no" end')"
assert_eq "not worth retrying" "false" "$(echo "$OUT" | jq -r .retryable)"
teardown

CASE="a repo lookup that fails on the network IS worth retrying"
setup
export FAKE_GH_REPOVIEW_EXIT=1 FAKE_GH_REPOVIEW_STDERR="error connecting to api.github.com"
OUT="$("$SCAN" --state "$STATE" --once 2>"$SANDBOX/stderr")"
assert_eq "retryable" "true" "$(echo "$OUT" | jq -r .retryable)"
teardown

# ---------- summary ----------

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
