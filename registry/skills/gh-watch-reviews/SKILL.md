---
name: gh-watch-reviews
description: Use when the user wants to watch the current GitHub repo for pull requests that need their review — new PRs, explicit review requests, re-requests after new commits — e.g. "watch for incoming reviews", "check PRs needing my review", as the recurring body of a /loop invocation, or to arm a background watcher. GitHub-only (gh CLI). Not for reviewing one specific known PR (invoke pr-review directly).
argument-hint: "[watch [interval] | reconfigure | exclude: <login>, ... | include-drafts]"
---

<!-- Deliberately NOT `context: fork`: this skill needs AskUserQuestion and the Skill tool, which forked/subagent skills cannot use (same constraint as pr-review). -->

# gh-watch-reviews

## Goal

Surface open PRs in the current repo that need the **user's** review and hand each to the `pr-review` skill, one at a time. This skill never reviews code itself and never posts anything to GitHub; `pr-review`'s own gates control publishing.

All discovery, filtering, and dedup logic is deterministic and lives in `scripts/scan.sh` (under this skill's base directory) — a pass costs one Bash call, and you act only on its JSON verdict. Don't re-derive its decisions.

**Dependency:** the `pr-review` skill from this registry. If it isn't available when a review should start, offer to install it first: `npx @provectusinc/awos-recruitment skill pr-review`.

## Inputs

`args` — one of:

- empty → one pass over the repo of the current working directory (`gh repo view --json nameWithOwner -q .nameWithOwner`)
- `watch [interval]` → arm the background watcher (see Watch mode); interval accepts `30s`/`10m`/`1h`, default 15m
- `reconfigure` → re-run the config interview (references/setup.md), keep `state` untouched, then do a normal pass
- ad-hoc overrides, applied to this invocation only: `exclude: <login>[, <login>…]` → `--exclude <login>` per login; `include-drafts` → `--include-drafts`

The recurring form is `watch`: quiet polling happens in a background script and costs the session nothing. A `/loop` body runs the same single pass but re-injects this skill every tick — if this invocation IS a recurring `/loop` tick, complete the pass normally and, once per session, add one line suggesting `/gh-watch-reviews watch` instead.

## One pass

1. On the first pass of this conversation session only: resolve the repo (`gh repo view --json nameWithOwner -q .nameWithOwner`) and Read `.claude/gh-watch-reviews.local.json`. If the file is absent, this is the first run — read references/setup.md and follow it (interview → write file). Otherwise: if `config.review_target` is missing (config from an older skill version), ask the one missing question — Where should reviews run? Ask each time (recommended) / Always here / Always in a new tab — and write the answer into `config` before anything else. Then print exactly one compact line so the user knows what's being watched — with the real `owner/repo`, so resolve it before printing — e.g. `gh-watch-reviews: watching owner/repo · bots excluded · drafts excluded · unrequested PRs on`. Later passes in the same session skip this step entirely — no re-read, no repeated line; a quiet later tick is exactly one tool call (the scanner reads the file itself, and its "state file not found" error is the first-run signal if the file has vanished).
2. Run the scanner — ONE Bash call:

```bash
bash "<skill-base-dir>/scripts/scan.sh" --repo <owner/repo> --state .claude/gh-watch-reviews.local.json --once
```

3. Act on the JSON `status`:

- `error` (exit 1) → emit exactly one line — `gh-watch-reviews: search failed — <message>` — and stop the pass. Never continue past a failure: a silent "nothing needs review" is the one outcome a watch must never produce from an error.
- `in_review` → a review handed off earlier is still being worked and this tick fired mid-review: **stop silently — produce no output at all.**
- `stale_in_progress` → an `in_progress` entry is older than 2h and the scanner could not resolve it from GitHub (no submitted review, PR still open). Ask the user whether that review is genuinely still running; if not, remove the listed entries from `state` (Read → modify → Write) and re-run the pass from step 2.
- `empty` → end the turn with exactly ONE compact heartbeat line and nothing else, using the returned `checked_at` verbatim (never invent, round, or approximate a timestamp): `gh-watch-reviews: owner/repo · no PRs need your review · checked <checked_at>`. This single line IS the entire quiet-tick deliverable — no second line, no summary of what was checked.
- `candidates` → read references/candidates.md and process them as it directs.

## Watch mode

`watch` replaces in-context polling: the same scanner runs as a background loop and only ends its silence when there is something to do.

1. Run step 1 above. If a watcher for this repo is already running in this session, say so and stop — never arm a second one.
2. Launch the scanner with `run_in_background` (no `--once`):

```bash
bash "<skill-base-dir>/scripts/scan.sh" --repo <owner/repo> --state .claude/gh-watch-reviews.local.json --interval <seconds> --log .claude/gh-watch-reviews.local.log
```

3. Tell the user in one line that the watch is armed and where the heartbeat log lives, then end the turn. The script polls quietly (heartbeats go to the log, not the session) and runs indefinitely — it exits only on: candidates found (exit 0), search/auth error (exit 1), or a stale `in_progress` entry (exit 4). If the session itself dies, the script notices it was orphaned and exits on its own — no zombie keeps polling GitHub.
4. When its completion notification arrives, act on the final JSON exactly as in "One pass" step 3, then: after a `candidates` pass finishes, re-arm (step 2). On exit 1 surface the error and do NOT re-arm silently — the user may need `gh auth login`. On exit 4 resolve the stale entry ("One pass" step 3), then re-arm.

## Notes

- Two watchers (or a watcher plus a `/loop`) on the same repo are unsupported — the state file has no locking; last write wins.
- Ad-hoc args never persist; only the setup interview writes `config`.
- State semantics, the interview, and candidate handling live in references/ — read them when the pass needs them, not preemptively.
