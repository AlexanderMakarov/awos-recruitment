#!/usr/bin/env bash
# scan.sh — deterministic discovery + dedup for the gh-watch-reviews skill.
#
# Finds open PRs in a GitHub repo that need the user's review, filtered by the
# config and dedup state in the skill's .claude/gh-watch-reviews.local.json.
# All dedup rules (sticky skips, re-request detection, in-progress suppression)
# live here so a quiet check costs the calling agent nothing but one invocation.
#
# in_progress entries are resolved against GitHub on every scan: a review the
# viewer submitted after the entry's `at` flips it to reviewed, a closed/merged
# PR prunes it. This is what lets reviews run in separate sessions that never
# touch this state file.
#
# One scan per invocation (--once). Recurring use is a scheduled tick that runs
# this again — see the skill's Recurring mode — not a long-lived loop here: this
# harness kills background commands after ~30 minutes, so a loop inside the
# script has to be resurrected about twice an hour, which costs more than it
# saves and is a failure mode of its own.
#
# stdout is always a single JSON object:
#   {"status":"candidates","checked_at":"...","candidates":[{number,title,author,url,createdAt,why}]}
#   {"status":"empty","checked_at":"...","line":"..."}
#   {"status":"in_review","checked_at":"..."}      (a review is in progress — the tick is a no-op, and says nothing)
#   {"status":"stale_in_progress","held_for_over_hours":N,"prs":[...]}
#                                                  (an in_progress entry has held the in-flight lock longer than
#                                                   --stale-hours / config.stale_review_hours / 2 — needs the user)
#   {"status":"error","message":"...","retryable":true|false}   (exit 1)
#            retryable = the network or GitHub was briefly unreachable, so the
#            next scheduled tick is worth running. The case that matters: the
#            scan due right after the machine wakes routinely beats Wi-Fi coming
#            back. Failures that need the user — auth, a bad state file — are
#            retryable:false and the caller should stop rather than re-run.
#
# `line` is the exact text the caller should print, absent when it should print
# nothing. It exists so a recurring tick is one call and one echo, with no
# timestamp for a model to round, reformat or invent.
#
# Exit codes: 0 any successful outcome, 1 error.
set -u

REPO="" STATE_FILE="" STALE_HOURS="" MARK_ARMED="" MARK_STOPPED=0
DEFAULT_STALE_HOURS=2
ADHOC_EXCLUDES=() ADHOC_DRAFTS=false
GH_OUT="" GH_ERR="" SCAN_MESSAGE="" SCAN_RETRYABLE=false

# Run gh, keeping stderr: whether a failure is worth retrying is only knowable
# from what gh printed there, and that difference decides whether the caller
# runs again or stops for the user.
gh_capture() {
  local err_file rc
  err_file="$(mktemp)" || { GH_OUT=""; GH_ERR="could not create a temp file"; return 1; }
  GH_OUT="$(gh "$@" 2>"$err_file")"; rc=$?
  GH_ERR="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return $rc
}

# Transient = the network or GitHub was briefly unavailable, and the identical
# call will likely work next tick. The case that matters most in practice: the
# machine just woke and the first scan runs before Wi-Fi is back. Anything not
# listed here — auth above all — is treated as needing the user, because a check
# that retries a bad token forever is a check that never tells anyone.
is_transient() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    *"error connecting to"*|*"could not resolve host"*|*"no such host"*|\
    *"connection refused"*|*"connection reset"*|*"network is unreachable"*|\
    *"i/o timeout"*|*"timeout awaiting"*|*"tls handshake timeout"*|\
    *"temporary failure in name resolution"*|*"eof"*|\
    *"rate limit"*|*"502 bad gateway"*|*"503 service"*|*"504 gateway"*|\
    *"server error"*) return 0 ;;
  esac
  return 1
}

# A failure inside a scan: recorded with its classification so the caller can
# tell "try again next tick" from "stop". Callers must `return 1` right after.
scan_fail() {
  SCAN_STATUS="error"
  SCAN_MESSAGE="$1"
  if is_transient "$GH_ERR"; then SCAN_RETRYABLE=true; else SCAN_RETRYABLE=false; fi
  [ -n "$GH_ERR" ] && SCAN_MESSAGE="$1 ($(printf '%s' "$GH_ERR" | tr '\n' ' ' | cut -c1-160))"
  SCAN_RESULT="$(jq -n --arg m "$SCAN_MESSAGE" --argjson r "$SCAN_RETRYABLE" \
    '{status: "error", message: $m, retryable: $r,
      line: ("gh-watch-reviews: search failed — " + $m)}')"
}

# Terminal failure: bad arguments, unusable state file, auth. Always
# retryable:false — the field is never absent, so a caller can branch on it
# without having to guess what a missing one meant.
fail() {
  jq -n --arg m "$1" '{status: "error", message: $m, retryable: false,
                       line: ("gh-watch-reviews: search failed — " + $m)}'
  exit 1
}

# A flag whose value is missing would otherwise expand "$2" unbound under
# `set -u`: bash writes to stderr and exits with nothing on stdout, breaking the
# promise in the header that stdout is always a single JSON object.
need_value() { [ $# -ge 2 ] || fail "missing value for argument: $1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --state) need_value "$@"; STATE_FILE="$2"; shift 2 ;;
    --once) shift ;;  # the only mode; accepted so the documented command reads clearly
    --stale-hours) need_value "$@"; STALE_HOURS="$2"; shift 2 ;;
    --mark-armed) need_value "$@"; MARK_ARMED="$2"; shift 2 ;;
    --mark-stopped) MARK_STOPPED=1; shift ;;
    --exclude) need_value "$@"; ADHOC_EXCLUDES+=("$2"); shift 2 ;;
    --include-drafts) ADHOC_DRAFTS=true; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

# Cannot route through fail(), which builds its JSON with jq. Hand-written so
# this path still satisfies the contract every other error path is tested for.
command -v jq >/dev/null 2>&1 || {
  echo '{"status":"error","message":"jq not found","retryable":false,"line":"gh-watch-reviews: search failed — jq not found"}'
  exit 1
}

command -v gh >/dev/null 2>&1 || fail "gh not found"

# Both of these default, so a caller that just wants "scan this repo" writes
# `scan.sh --once` and nothing else. That matters beyond convenience: the
# recurring form embeds this command in a scheduled prompt, and a prompt
# carrying absolute paths and an owner/repo is machine-specific — it cannot be
# shipped in a skill, reviewed, or moved between checkouts.
# Anchored to the repository root rather than the working directory, so it
# resolves the same from a subdirectory.
if [ -z "$STATE_FILE" ]; then
  STATE_FILE="$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.claude/gh-watch-reviews.local.json"
fi

# Rewrite the state file through a temp file: the calling agent also does
# Read → modify → Write on it, and a half-written state file is worse than a
# stale one.
write_state_file() {
  local tmp
  tmp="$(mktemp)" || return 1
  if jq "$1" "$STATE_FILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
}

# `check` records that a recurring check is *supposed* to be running here, and
# when it last actually ran. The schedule itself lives in Claude Code's memory
# and dies with the session, leaving nothing behind — so without this, a check
# that stopped overnight looks exactly like one that was never set up, and the
# silence reads as "no PRs need your review". Marked armed when the recurring
# form is set up, cleared when the user stops it, stamped by every scan.
if [ -n "$MARK_ARMED" ] || [ "$MARK_STOPPED" = 1 ]; then
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE (run the skill once to create it)"
  if [ "$MARK_STOPPED" = 1 ]; then
    write_state_file 'del(.check)' || fail "could not clear the check marker in $STATE_FILE"
    jq -n '{status: "check_cleared"}'
  else
    case "$MARK_ARMED" in ''|*[!0-9]*) fail "--mark-armed takes whole minutes, got: $MARK_ARMED" ;; esac
    [ "$MARK_ARMED" -gt 0 ] || fail "--mark-armed must be greater than zero"
    write_state_file "$(printf '.check = {interval_minutes: %s, armed_at: "%s", last_check_at: "%s", last_check_epoch: %s}' \
        "$MARK_ARMED" "$(date '+%F %T %Z')" "$(date '+%F %T %Z')" "$(date +%s)")" \
      || fail "could not write the check marker to $STATE_FILE"
    jq -n --argjson m "$MARK_ARMED" '{status: "check_armed", interval_minutes: $m}'
  fi
  exit 0
fi

# The auth gate must not become a network gate: right after a wake, `gh auth
# status` fails because it cannot reach github.com, which says nothing about the
# token. Only a genuine auth failure stops us here; a transient one falls
# through to the scan, which has its own retry policy.
if ! gh_capture auth status; then
  is_transient "$GH_ERR" || fail "gh is not authenticated — run: gh auth login"
fi

# Resolved after the auth gate, since it is itself an API call. A failure here
# gets the same transient/terminal split as any other: unreachable now is worth
# another tick, "not a repository" is not.
if [ -z "$REPO" ]; then
  if gh_capture repo view --json nameWithOwner -q .nameWithOwner && [ -n "$GH_OUT" ]; then
    REPO="$GH_OUT"
  else
    scan_fail "could not resolve the repo — pass --repo owner/name"
    echo "$SCAN_RESULT"
    exit 1
  fi
fi

ADHOC_EXCLUDES_JSON="$(printf '%s\n' "${ADHOC_EXCLUDES[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"

now() { date '+%F %T %Z'; }

JSON_FIELDS="number,title,author,url,isDraft,createdAt"

# One scan. Sets SCAN_STATUS to "candidates" or "empty"; on "candidates" sets
# SCAN_RESULT to the final result JSON. Any failure inside becomes an error
# result — a failed check must never be reported as a quiet one.
scan() {
  SCAN_STATUS="" SCAN_MESSAGE="" SCAN_RETRYABLE=false GH_ERR=""
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE (run the skill once to create it)"
  jq -e 'has("config") and has("state")' "$STATE_FILE" >/dev/null 2>&1 \
    || fail "state file is not valid gh-watch-reviews JSON: $STATE_FILE"

  # How long a review may hold the in-flight lock before the user is asked about
  # it: --stale-hours wins, else config.stale_review_hours, else the default.
  # Re-read per scan, so editing the config takes effect on the next tick.
  local stale_hours stale_seconds
  stale_hours="$STALE_HOURS"
  if [ -z "$stale_hours" ]; then
    stale_hours="$(jq -r --argjson d "$DEFAULT_STALE_HOURS" \
      '(.config.stale_review_hours // $d) | tostring' "$STATE_FILE" 2>/dev/null)" \
      || stale_hours="$DEFAULT_STALE_HOURS"
  fi
  case "$stale_hours" in
    ''|*[!0-9.]*) fail "stale_review_hours must be a positive number, got: $stale_hours" ;;
  esac
  stale_seconds="$(jq -n --argjson h "$stale_hours" '($h * 3600) | floor')" \
    || fail "could not compute the staleness threshold from: $stale_hours"
  [ "$stale_seconds" -gt 0 ] || fail "stale_review_hours must be greater than zero"

  # In-flight guard: an in_progress entry means a review is being worked right
  # now — the whole scan is a no-op until it completes. But first try to
  # resolve each entry from GitHub: a review running in a separate session
  # can't write this file, so a submitted review (or a closed/merged PR) must
  # be detected here, not assumed to be flipped by whoever launched it.
  local guard
  guard="$(jq --argjson now "$(date -u +%s)" \
    '[.state | to_entries[] | select(.value.decision == "in_progress")
      | {number: .key, at: .value.at, age: ($now - (.value.at | try fromdateiso8601 catch 0))}]' \
    "$STATE_FILE")" || fail "in-flight guard check failed"

  if [ "$(echo "$guard" | jq 'length')" -gt 0 ]; then
    if [ -z "${VIEWER:-}" ]; then
      gh_capture api user -q .login || { scan_fail "could not resolve the gh viewer login"; return 1; }
      VIEWER="$GH_OUT"
    fi
    local entry n at pr resolution tmp
    while IFS= read -r entry; do
      n="$(echo "$entry" | jq -r '.number')"
      at="$(echo "$entry" | jq -r '.at')"
      gh_capture pr view "$n" --repo "$REPO" --json state,reviews \
        || { scan_fail "in-progress check failed for PR #$n"; return 1; }
      pr="$GH_OUT"
      resolution="$(echo "$pr" | jq -r --arg login "$VIEWER" --arg at "$at" '
        if .state != "OPEN" then "prune"
        elif ([.reviews[] | select(.author.login == $login
                and ((.submittedAt | try fromdateiso8601 catch 0)
                     >= ($at | try fromdateiso8601 catch 0)))] | length) > 0
        then "reviewed"
        else "open" end')" \
        || fail "in-progress resolution failed for PR #$n"
      if [ "$resolution" != "open" ]; then
        tmp="$(mktemp)"
        if [ "$resolution" = "prune" ]; then
          jq --arg n "$n" 'del(.state[$n])' "$STATE_FILE" > "$tmp"
        else
          jq --arg n "$n" --arg t "$(date -u +%FT%TZ)" \
            '.state[$n].decision = "reviewed" | .state[$n].at = $t' "$STATE_FILE" > "$tmp"
        fi
        if [ -s "$tmp" ]; then
          mv "$tmp" "$STATE_FILE" || { rm -f "$tmp"; fail "state update failed for PR #$n"; }
        else
          rm -f "$tmp"
          fail "state update failed for PR #$n"
        fi
      fi
    done <<< "$(echo "$guard" | jq -c '.[]')"
    guard="$(jq --argjson now "$(date -u +%s)" \
      '[.state | to_entries[] | select(.value.decision == "in_progress")
        | {number: .key, at: .value.at, age: ($now - (.value.at | try fromdateiso8601 catch 0))}]' \
      "$STATE_FILE")" || fail "in-flight guard recheck failed"
  fi

  # What survives resolution: an entry held longer than the threshold is
  # probably a review that died (closed tab, killed session) and will never
  # resolve itself; nothing here can tell that from a slow review, so surface it
  # and let the user say. An unparseable `at` counts as stale — it must reach
  # the user, not hide.
  if [ "$(echo "$guard" | jq --argjson s "$stale_seconds" '[.[] | select(.age >= $s)] | length')" -gt 0 ]; then
    SCAN_STATUS="stale_in_progress"
    SCAN_RESULT="$(echo "$guard" | jq --argjson s "$stale_seconds" --argjson h "$stale_hours" \
      '{status: "stale_in_progress", held_for_over_hours: $h, prs: [.[] | select(.age >= $s) | .number | tonumber]}')"
    return
  fi
  if [ "$(echo "$guard" | jq 'length')" -gt 0 ]; then
    SCAN_STATUS="in_review"
    SCAN_RESULT=""
    return
  fi

  local requested unrequested
  gh_capture search prs --review-requested=@me --state open --repo "$REPO" \
    --json "$JSON_FIELDS" --limit 50 \
    || { scan_fail "review-requested search failed"; return 1; }
  requested="$GH_OUT"
  echo "$requested" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || { GH_ERR=""; scan_fail "review-requested search returned non-JSON output"; return 1; }

  if jq -e '.config.watch_unrequested' "$STATE_FILE" >/dev/null; then
    gh_capture search prs --state open --repo "$REPO" \
      --json "$JSON_FIELDS" --limit 50 -- -reviewed-by:@me -author:@me \
      || { scan_fail "unreviewed-PRs search failed"; return 1; }
    unrequested="$GH_OUT"
    echo "$unrequested" | jq -e 'type == "array"' >/dev/null 2>&1 \
      || { GH_ERR=""; scan_fail "unreviewed-PRs search returned non-JSON output"; return 1; }
  else
    unrequested="[]"
  fi

  # Pass 1: union, filter, apply every dedup rule that needs no extra API call.
  # PRs whose rule depends on the current head SHA (sticky skip of an explicit
  # request) come back under "checks" for pass 2.
  local pass1
  pass1="$(jq -n \
    --argjson requested "$requested" \
    --argjson unrequested "$unrequested" \
    --argjson adhoc_ex "$ADHOC_EXCLUDES_JSON" \
    --argjson adhoc_drafts "$ADHOC_DRAFTS" \
    --slurpfile file "$STATE_FILE" '
    $file[0].config as $cfg | $file[0].state as $st |
    def slim(why): {number, title, author: .author.login, url, createdAt, why: why};
    def keyed(arr; v): arr | map({key: (.number | tostring), value: (. + {via: v})}) | from_entries;
    (keyed($unrequested; "unrequested") + keyed($requested; "requested")) | [.[]]
    | map(select(($cfg.exclude_bots and .author.is_bot) | not))
    # IN(), not inside(): `inside` compares strings by substring, so excluding
    # "alice" also suppressed an unrelated author "ali" — a PR needing review
    # silently never surfacing.
    | map(select((.author.login | IN((($cfg.exclude_authors // []) + $adhoc_ex)[])) | not))
    | map(select((.isDraft and (($cfg.include_drafts or $adhoc_drafts) | not)) | not))
    | map(. as $p | $st[($p.number | tostring)] as $e |
        if $e == null then
          {emit: ($p | slim(if $p.via == "requested" then "review requested" else "never reviewed" end))}
        elif $e.decision == "in_progress" or $p.via != "requested" then
          empty
        elif $e.decision == "reviewed" then
          {emit: ($p | slim("re-requested after your review"))}
        elif $e.via == "unrequested" then
          {emit: ($p | slim("review requested — previously skipped"))}
        else
          {check: (($p | slim("")) + {sha: $e.sha})}
        end)
    | {emits: map(.emit // empty), checks: map(.check // empty)}')" \
    || fail "dedup filtering failed"

  # Pass 2: sticky skips of an explicit request resurface only on new commits.
  local candidates checks n sha head
  candidates="$(echo "$pass1" | jq '.emits')"
  checks="$(echo "$pass1" | jq -c '.checks[]')"
  if [ -n "$checks" ]; then
    while IFS= read -r check; do
      n="$(echo "$check" | jq -r '.number')"
      sha="$(echo "$check" | jq -r '.sha')"
      gh_capture pr view "$n" --repo "$REPO" --json headRefOid \
        || { scan_fail "head fetch failed for PR #$n"; return 1; }
      head="$(echo "$GH_OUT" | jq -r '.headRefOid')"
      if [ "$head" != "$sha" ]; then
        candidates="$(echo "$candidates" | jq --argjson c "$check" \
          '. + [$c | del(.sha) | .why = "new commits since your last decision"]')"
      fi
    done <<< "$checks"
  fi

  if [ "$(echo "$candidates" | jq 'length')" -gt 0 ]; then
    SCAN_STATUS="candidates"
    SCAN_RESULT="$(echo "$candidates" | jq --arg t "$(now)" \
      '{status: "candidates", checked_at: $t, candidates: sort_by(.createdAt)}')"
  else
    SCAN_STATUS="empty"
    SCAN_RESULT=""
  fi
}

# Was the recurring check still running? Judged before this run stamps itself,
# against twice the interval — one missed tick is a sleeping machine, two is a
# schedule that no longer exists. Only ever reported when a check was actually
# set up here; a one-off pass must never nag about a check nobody asked for.
CHECK_EXTRA='{}'
if [ -f "$STATE_FILE" ] && jq -e 'has("check")' "$STATE_FILE" >/dev/null 2>&1; then
  CHECK_EXTRA="$(jq --argjson now "$(date +%s)" '
    .check as $c
    | (($c.interval_minutes // 15) * 60 * 2) as $grace
    | if (($now - ($c.last_check_epoch // 0)) > $grace)
      then {check_stale: true, check_interval_minutes: ($c.interval_minutes // 15),
            check_last_at: ($c.last_check_at // "never")}
      else {} end' "$STATE_FILE" 2>/dev/null)" || CHECK_EXTRA='{}'
  [ -n "$CHECK_EXTRA" ] || CHECK_EXTRA='{}'
  write_state_file "$(printf '.check.last_check_at = "%s" | .check.last_check_epoch = %s' \
      "$(date '+%F %T %Z')" "$(date +%s)")" || true
fi

scan
case "$SCAN_STATUS" in
  candidates | stale_in_progress) RESULT="$SCAN_RESULT" ;;
  # One pass has no next poll to retry on, so an error is still an error —
  # but it carries `retryable` so the caller knows whether re-running is
  # worth anything or a human has to act.
  error) echo "$SCAN_RESULT" | jq --argjson e "$CHECK_EXTRA" '. + $e'; exit 1 ;;
  # `line` is the exact text the caller should print, or absent when the
  # caller should say nothing. It exists so a recurring caller (a /loop tick)
  # is one Bash call and one echo — with no timestamp for a model to round,
  # reformat or invent, which is the one thing a heartbeat must never do.
  in_review) RESULT="$(jq -n --arg t "$(now)" '{status: "in_review", checked_at: $t}')" ;;
  *) RESULT="$(jq -n --arg t "$(now)" --arg r "$REPO" \
         '{status: "empty", checked_at: $t,
           line: ("gh-watch-reviews: " + $r + " · no PRs need your review · checked " + $t)}')" ;;
esac
echo "$RESULT" | jq --argjson e "$CHECK_EXTRA" '. + $e'
exit 0
