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
#   (default) watch loop: rescan every --interval seconds until candidates
#            appear (exit 0) or an error occurs (exit 1). Runs indefinitely;
#            each poll checks for orphaning (PPID 1 — the launching session
#            died) and exits silently, so no zombie keeps polling GitHub.
#            An explicit --ttl N makes it exit 3 after N seconds instead
#            (used by tests; default 0 = no TTL). Quiet polls append a
#            heartbeat line to --log.
#
# stdout is always a single JSON object:
#   {"status":"candidates","checked_at":"...","candidates":[{number,title,author,url,createdAt,why}]}
#   {"status":"empty","checked_at":"..."}          (--once only)
#   {"status":"in_review","checked_at":"..."}      (--once only: a review is in progress — the tick is a no-op)
#   {"status":"stale_in_progress","prs":[...]}     (in_progress entry older than 2h — needs the user; watch exit 4)
#   {"status":"expired","checked_at":"..."}        (watch TTL, exit 3)
#   {"status":"error","message":"..."}             (exit 1)
#
# Exit codes: 0 candidates found (or any --once outcome), 1 error,
#             3 watch TTL expired, 4 stale in_progress entry (watch mode).
set -u

REPO="" STATE_FILE="" ONCE=0 INTERVAL=900 TTL=0 LOG_FILE=""
ADHOC_EXCLUDES=() ADHOC_DRAFTS=false

fail() {
  jq -n --arg m "$1" '{status: "error", message: $m}'
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --state) STATE_FILE="$2"; shift 2 ;;
    --once) ONCE=1; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --ttl) TTL="$2"; shift 2 ;;
    --log) LOG_FILE="$2"; shift 2 ;;
    --exclude) ADHOC_EXCLUDES+=("$2"); shift 2 ;;
    --include-drafts) ADHOC_DRAFTS=true; shift ;;
    *) fail "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo '{"status":"error","message":"jq not found"}'; exit 1; }
command -v gh >/dev/null 2>&1 || fail "gh not found"
[ -n "$REPO" ] || fail "--repo is required"
[ -n "$STATE_FILE" ] || fail "--state is required"

gh auth status >/dev/null 2>&1 || fail "gh is not authenticated — run: gh auth login"

ADHOC_EXCLUDES_JSON="$(printf '%s\n' "${ADHOC_EXCLUDES[@]:-}" | jq -R . | jq -s 'map(select(length > 0))')"

now() { date '+%F %T %Z'; }

JSON_FIELDS="number,title,author,url,isDraft,createdAt"

# One scan. Sets SCAN_STATUS to "candidates" or "empty"; on "candidates" sets
# SCAN_RESULT to the final result JSON. Any failure inside prints an error
# result and exits 1 — a watch must never turn a failure into a quiet poll.
scan() {
  [ -f "$STATE_FILE" ] || fail "state file not found: $STATE_FILE (run the skill once to create it)"
  jq -e 'has("config") and has("state")' "$STATE_FILE" >/dev/null 2>&1 \
    || fail "state file is not valid gh-watch-reviews JSON: $STATE_FILE"

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
      VIEWER="$(gh api user -q .login)" || fail "could not resolve the gh viewer login"
    fi
    local entry n at pr resolution tmp
    while IFS= read -r entry; do
      n="$(echo "$entry" | jq -r '.number')"
      at="$(echo "$entry" | jq -r '.at')"
      pr="$(gh pr view "$n" --repo "$REPO" --json state,reviews)" \
        || fail "in-progress check failed for PR #$n"
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

  # What survives resolution: an entry older than 2h is probably a crashed
  # review; only the user can say, so surface it. An unparseable `at` counts
  # as stale — it must reach the user, not hide.
  if [ "$(echo "$guard" | jq '[.[] | select(.age >= 7200)] | length')" -gt 0 ]; then
    SCAN_STATUS="stale_in_progress"
    SCAN_RESULT="$(echo "$guard" | jq '{status: "stale_in_progress", prs: [.[] | select(.age >= 7200) | .number | tonumber]}')"
    return
  fi
  if [ "$(echo "$guard" | jq 'length')" -gt 0 ]; then
    SCAN_STATUS="in_review"
    SCAN_RESULT=""
    return
  fi

  local requested unrequested
  requested="$(gh search prs --review-requested=@me --state open --repo "$REPO" \
    --json "$JSON_FIELDS" --limit 50)" \
    || fail "review-requested search failed"
  echo "$requested" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || fail "review-requested search returned non-JSON output"

  if jq -e '.config.watch_unrequested' "$STATE_FILE" >/dev/null; then
    unrequested="$(gh search prs --state open --repo "$REPO" \
      --json "$JSON_FIELDS" --limit 50 -- -reviewed-by:@me -author:@me)" \
      || fail "unreviewed-PRs search failed"
    echo "$unrequested" | jq -e 'type == "array"' >/dev/null 2>&1 \
      || fail "unreviewed-PRs search returned non-JSON output"
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
      head="$(gh pr view "$n" --repo "$REPO" --json headRefOid | jq -r '.headRefOid')" \
        || fail "head fetch failed for PR #$n"
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
    in_review) jq -n --arg t "$(now)" '{status: "in_review", checked_at: $t}' ;;
    *) jq -n --arg t "$(now)" '{status: "empty", checked_at: $t}' ;;
  esac
  exit 0
fi

# Watch loop.
START=$SECONDS
while :; do
  if [ "$(ps -o ppid= -p $$ | tr -d ' ')" = "1" ]; then
    if [ -n "$LOG_FILE" ]; then
      echo "gh-watch-reviews: $REPO · session gone — watcher exiting · $(now)" >> "$LOG_FILE"
    fi
    exit 0
  fi
  scan
  case "$SCAN_STATUS" in
    candidates)
      echo "$SCAN_RESULT"
      exit 0
      ;;
    stale_in_progress)
      echo "$SCAN_RESULT"
      exit 4
      ;;
    in_review)
      if [ -n "$LOG_FILE" ]; then
        echo "gh-watch-reviews: $REPO · review in progress — watching paused · checked $(now)" >> "$LOG_FILE"
      fi
      ;;
    *)
      if [ -n "$LOG_FILE" ]; then
        echo "gh-watch-reviews: $REPO · no PRs need your review · checked $(now)" >> "$LOG_FILE"
      fi
      ;;
  esac
  if [ "$TTL" -gt 0 ] && [ $((SECONDS - START)) -ge "$TTL" ]; then
    jq -n --arg t "$(now)" '{status: "expired", checked_at: $t}'
    exit 3
  fi
  sleep "$INTERVAL"
done
