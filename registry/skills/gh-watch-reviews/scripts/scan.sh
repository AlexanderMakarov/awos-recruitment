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
# Modes:
#   --once   one scan; prints a result JSON and exits.
#   --status report whether the watcher named by --pidfile is still running.
#   (default) watch loop: rescan every --interval seconds until candidates
#            appear (exit 0) or an error occurs (exit 1). Runs indefinitely;
#            each poll checks for orphaning (PPID 1 — the launching session
#            died) and exits silently, so no zombie keeps polling GitHub.
#            An explicit --ttl N makes it exit 3 after N seconds instead
#            (used by tests; default 0 = no TTL). Quiet polls append a
#            heartbeat line to --log.
#
# The wait between polls is a wall-clock deadline walked in --poll-step chunks,
# not one long sleep. Two reasons: the orphan check then runs every step instead
# of once per interval, and macOS does not count time spent asleep towards
# sleep(1), so a single `sleep $INTERVAL` would leave the watcher silent for a
# further full interval after the machine wakes. Comparing `date +%s` against
# the deadline makes a wake-up scan immediately.
#
# --pidfile is how a watch outlives the Claude Code process that armed it: the
# file is written at launch and removed only on the watcher's OWN exit paths
# (candidates, error, TTL, orphan). A pidfile whose pid is gone therefore means
# "armed, then killed from outside" — a session restart, a machine sleep that
# took the terminal with it, a UI stop — which is what tells the skill to
# re-arm. No pidfile means no watch is meant to be running.
#
# Each completed poll stamps last_poll_at/last_poll_epoch into it, so --status
# can report ran_for_seconds: a watcher killed after polling happily for an hour
# and one that fell over on startup both end as "watch_dead", but only the
# second means anything is wrong.
#
# stdout is always a single JSON object:
#   {"status":"candidates","checked_at":"...","candidates":[{number,title,author,url,createdAt,why}]}
#   {"status":"empty","checked_at":"..."}          (--once only)
#   {"status":"in_review","checked_at":"..."}      (--once only: a review is in progress — the tick is a no-op)
#   {"status":"stale_in_progress","held_for_over_hours":N,"prs":[...]}
#                                                  (an in_progress entry has held the in-flight lock longer than
#                                                   --stale-hours / config.stale_review_hours / 2 — needs the user; watch exit 4)
#   {"status":"expired","checked_at":"..."}        (watch TTL, exit 3)
#   {"status":"error","message":"...","retryable":true|false}   (exit 1)
#            retryable = the network or GitHub was briefly unreachable. Watch
#            mode retries those in place (--max-transient, default 3 consecutive
#            polls) rather than exiting, because the scan due right after the
#            machine wakes routinely beats Wi-Fi coming back, and dying there
#            leaves the watch off until a human notices. Failures that need the
#            user — auth, a bad state file — still exit on the first one.
#   {"status":"watch_running"|"watch_dead"|"watch_absent",...}  (--status only)
#
# Exit codes: 0 candidates found (or any --once/--status outcome), 1 error,
#             3 watch TTL expired, 4 stale in_progress entry (watch mode).
set -u

REPO="" STATE_FILE="" ONCE=0 STATUS_ONLY=0 INTERVAL=900 TTL=0 POLL_STEP=30
LOG_FILE="" PIDFILE="" OWN_PIDFILE=0 STALE_HOURS=""
DEFAULT_STALE_HOURS=2
MAX_TRANSIENT=3
ADHOC_EXCLUDES=() ADHOC_DRAFTS=false
GH_OUT="" GH_ERR="" SCAN_MESSAGE="" SCAN_RETRYABLE=false

# Run gh, keeping stderr: whether a failure is worth retrying is only knowable
# from what gh printed there, and the difference decides whether a watch keeps
# going or stops for the user.
gh_capture() {
  local err_file rc
  err_file="$(mktemp)" || { GH_OUT=""; GH_ERR="could not create a temp file"; return 1; }
  GH_OUT="$(gh "$@" 2>"$err_file")"; rc=$?
  GH_ERR="$(cat "$err_file" 2>/dev/null)"
  rm -f "$err_file"
  return $rc
}

# Transient = the network or GitHub was briefly unavailable, and the identical
# call will likely work next poll. The case that matters most in practice: the
# machine just woke and the first scan runs before Wi-Fi is back. Anything not
# listed here — auth above all — is treated as needing the user, because a watch
# that retries a bad token forever is a watch that never tells anyone.
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

# A failure inside a scan: recorded rather than fatal, so watch mode can decide
# between retrying and giving up. Callers must `return 1` right after.
scan_fail() {
  SCAN_STATUS="error"
  SCAN_MESSAGE="$1"
  if is_transient "$GH_ERR"; then SCAN_RETRYABLE=true; else SCAN_RETRYABLE=false; fi
  [ -n "$GH_ERR" ] && SCAN_MESSAGE="$1 ($(printf '%s' "$GH_ERR" | tr '\n' ' ' | cut -c1-160))"
  SCAN_RESULT="$(jq -n --arg m "$SCAN_MESSAGE" --argjson r "$SCAN_RETRYABLE" \
    '{status: "error", message: $m, retryable: $r,
      line: ("gh-watch-reviews: search failed — " + $m)}')"
}

# Remove the pidfile — only ever called on an exit this script chose. Anything
# that kills the watcher without running this leaves the file behind on purpose.
release_pidfile() {
  [ "$OWN_PIDFILE" = 1 ] || return 0
  rm -f "$PIDFILE"
  OWN_PIDFILE=0
}

# Stamp the last completed poll into the pidfile. This is what lets a later
# --status say how long a watcher that is now dead actually ran for: armed_at
# alone can't distinguish "polled happily for an hour, then something killed it"
# from "died seconds after arming", and those need opposite responses.
# Never recreates a removed pidfile — a deliberate stop deletes it, and this
# must not race that away.
stamp_pidfile() {
  [ "$OWN_PIDFILE" = 1 ] || return 0
  [ -f "$PIDFILE" ] || return 0
  local tmp
  tmp="$(mktemp)" || return 0
  if jq --argjson e "$(date +%s)" --arg t "$(now)" \
      '. + {last_poll_at: $t, last_poll_epoch: $e}' "$PIDFILE" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mv "$tmp" "$PIDFILE" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

# Terminal failure: bad arguments, unusable state file, auth. Always
# retryable:false — the field is never absent, so a caller can branch on it
# without having to guess what a missing one meant.
fail() {
  release_pidfile
  jq -n --arg m "$1" '{status: "error", message: $m, retryable: false,
                       line: ("gh-watch-reviews: search failed — " + $m)}'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --state) STATE_FILE="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --status) STATUS_ONLY=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --poll-step) POLL_STEP="$2"; shift 2 ;;
    --stale-hours) STALE_HOURS="$2"; shift 2 ;;
    --max-transient) MAX_TRANSIENT="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --pidfile) PIDFILE="$2"; shift 2 ;;
    --exclude) ADHOC_EXCLUDES+=("$2"); shift 2 ;;
    --include-drafts) ADHOC_DRAFTS=true; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo '{"status":"error","message":"jq not found"}'; exit 1; }

# --status answers one question — is the armed watcher still alive? — and needs
# neither gh nor the state file, so it runs before their checks. It must stay
# cheap: the skill calls it on a first pass just to notice a watch that died.
if [ "$STATUS_ONLY" = 1 ]; then
  [ -n "$PIDFILE" ] || fail "--status requires --pidfile"
  [ -f "$PIDFILE" ] || { jq -n '{status: "watch_absent"}'; exit 0; }
  WPID="$(jq -r '.pid // empty' "$PIDFILE" 2>/dev/null)" || WPID=""
  # A pid alone is not proof: pids get reused, so confirm it is still this
  # script before believing the watch is up.
  # ran_for_seconds: armed_at → last completed poll. For a dead watcher this is
  # the difference between "killed while healthy" (re-arm it) and "died on
  # startup" (something is broken — stop and say so), so it is computed here
  # rather than left to date arithmetic at the call site.
  # null, not 0, when the pidfile predates poll stamping: "I cannot tell" and
  # "died before its first poll" call for opposite responses, and a pidfile
  # written by an older version must not be read as a crash-on-startup.
  STATUS_JQ='. + {ran_for_seconds: (if (.armed_at_epoch | not) then null
                                    elif (.last_poll_epoch | not) then 0
                                    else (.last_poll_epoch - .armed_at_epoch) end)}'
  if [ -n "$WPID" ] && kill -0 "$WPID" 2>/dev/null \
     && ps -o command= -p "$WPID" 2>/dev/null | grep -q 'scan\.sh'; then
    jq "$STATUS_JQ"' + {status: "watch_running"}' "$PIDFILE" 2>/dev/null \
      || jq -n --argjson p "$WPID" '{status: "watch_running", pid: $p, ran_for_seconds: 0}'
  else
    jq "$STATUS_JQ"' + {status: "watch_dead"}' "$PIDFILE" 2>/dev/null \
      || jq -n '{status: "watch_dead", ran_for_seconds: 0}'
  fi
  exit 0
fi

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
# SCAN_RESULT to the final result JSON. Any failure inside prints an error
# result and exits 1 — a watch must never turn a failure into a quiet poll.
scan() {
  SCAN_STATUS="" SCAN_MESSAGE="" SCAN_RETRYABLE=false GH_ERR=""
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE (run the skill once to create it)"
  jq -e 'has("config") and has("state")' "$STATE_FILE" >/dev/null 2>&1 \
    || fail "state file is not valid gh-watch-reviews JSON: $STATE_FILE"

  # How long a review may hold the in-flight lock before the user is asked about
  # it: --stale-hours wins, else config.stale_review_hours, else the default.
  # Re-read per scan so an edit to the config takes effect without a re-arm.
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
    | map(select(([.author.login] | inside($cfg.exclude_authors + $adhoc_ex)) | not))
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

if [ "$ONCE" = 1 ]; then
  scan
  case "$SCAN_STATUS" in
    candidates | stale_in_progress) echo "$SCAN_RESULT" ;;
    # One pass has no next poll to retry on, so an error is still an error —
    # but it carries `retryable` so the caller knows whether re-running is
    # worth anything or a human has to act.
    error) echo "$SCAN_RESULT"; exit 1 ;;
    # `line` is the exact text the caller should print, or absent when the
    # caller should say nothing. It exists so a recurring caller (a /loop tick)
    # is one Bash call and one echo — with no timestamp for a model to round,
    # reformat or invent, which is the one thing a heartbeat must never do.
    in_review) jq -n --arg t "$(now)" '{status: "in_review", checked_at: $t}' ;;
    *) jq -n --arg t "$(now)" --arg r "$REPO" \
         '{status: "empty", checked_at: $t,
           line: ("gh-watch-reviews: " + $r + " · no PRs need your review · checked " + $t)}' ;;
  esac
  exit 0
fi

# Watch loop.
log_line() { [ -n "$LOG_FILE" ] && echo "gh-watch-reviews: $REPO · $1" >> "$LOG_FILE"; }

# The launching session is gone (we were reparented to init): stop polling.
# This only fires when the watcher outlives its parent — a Claude Code process
# that is torn down normally takes its children with it, which is why the
# pidfile, not this check, is what makes a dead watch noticeable afterwards.
check_orphaned() {
  [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "1" ] || return 0
  log_line "session gone — watcher exiting · $(now)"
  release_pidfile
  exit 0
}

check_ttl() {
  [ "$TTL" -gt 0 ] || return 0
  [ $(( $(date +%s) - START )) -ge "$TTL" ] || return 0
  release_pidfile
  jq -n --arg t "$(now)" '{status: "expired", checked_at: $t}'
  exit 3
}

# Wait until the next scan is due, in POLL_STEP chunks, against a wall-clock
# deadline: see the --poll-step note in the header.
wait_for_next_scan() {
  local due remaining
  due=$(( $(date +%s) + INTERVAL ))
  while :; do
    remaining=$(( due - $(date +%s) ))
    [ "$remaining" -le 0 ] && return 0
    check_ttl
    check_orphaned
    if [ "$remaining" -lt "$POLL_STEP" ]; then sleep "$remaining"; else sleep "$POLL_STEP"; fi
  done
}

START=$(date +%s)
if [ -n "$PIDFILE" ]; then
  jq -n --argjson p "$$" --arg r "$REPO" --argjson i "$INTERVAL" --arg t "$(now)" \
    --argjson e "$(date +%s)" \
    '{pid: $p, repo: $r, interval: $i, armed_at: $t, armed_at_epoch: $e}' > "$PIDFILE" \
    || fail "could not write the pidfile: $PIDFILE"
  OWN_PIDFILE=1
fi
log_line "watch armed · every ${INTERVAL}s · pid $$ · $(now)"

TRANSIENT_STREAK=0
while :; do
  check_orphaned
  scan
  case "$SCAN_STATUS" in
    candidates)
      release_pidfile
      echo "$SCAN_RESULT"
      exit 0
      ;;
    stale_in_progress)
      release_pidfile
      echo "$SCAN_RESULT"
      exit 4
      ;;
    error)
      # A watch outlives the conditions it was armed under. The common failure
      # is not a broken setup but a few unreachable seconds — most often the
      # first scan after the machine wakes, before Wi-Fi is back — and exiting
      # for that means the watch stays dead until a human notices. Retry those,
      # loudly in the log so a failing check is never mistaken for a quiet one,
      # and give up only once it is clearly not a blip. Everything else (auth
      # above all) still exits immediately: it needs the user, not patience.
      if [ "$SCAN_RETRYABLE" = true ] && [ "$TRANSIENT_STREAK" -lt "$((MAX_TRANSIENT - 1))" ]; then
        TRANSIENT_STREAK=$((TRANSIENT_STREAK + 1))
        log_line "check failed, retrying ($TRANSIENT_STREAK/$MAX_TRANSIENT) — $SCAN_MESSAGE · $(now)"
        wait_for_next_scan
        continue
      fi
      release_pidfile
      log_line "check failed — giving up after $((TRANSIENT_STREAK + 1)) attempt(s) — $SCAN_MESSAGE · $(now)"
      echo "$SCAN_RESULT"
      exit 1
      ;;
    in_review)
      TRANSIENT_STREAK=0
      stamp_pidfile
      log_line "review in progress — watching paused · checked $(now)"
      ;;
    *)
      TRANSIENT_STREAK=0
      stamp_pidfile
      log_line "no PRs need your review · checked $(now)"
      ;;
  esac
  wait_for_next_scan
done
