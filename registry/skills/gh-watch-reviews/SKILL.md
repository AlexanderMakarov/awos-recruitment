---
name: gh-watch-reviews
description: Use when the user wants to watch the current GitHub repo for pull requests that need their review — new PRs, explicit review requests, re-requests after new commits — e.g. "watch for incoming reviews", "check PRs needing my review", as the recurring body of a /loop invocation, or to arm a background watcher. GitHub-only (gh CLI). Not for reviewing one specific known PR (invoke pr-review directly).
argument-hint: "[loop [interval] | watch [interval] | reconfigure | exclude: <login>, ... | include-drafts]"
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
- `loop [interval]` → set up the recurring tick (see Recurring mode). **This is the recommended recurring form.**
- `watch [interval]` → arm the background watcher (see Watch mode). `interval` accepts `30s`/`10m`/`1h` and overrides `config.poll_interval_minutes` for this invocation only; with no argument the configured value is used (15m if the config predates the setting)
- `reconfigure` → re-run the config interview (references/setup.md), keep `state` untouched, then do a normal pass
- ad-hoc overrides, applied to this invocation only: `exclude: <login>[, <login>…]` → `--exclude <login>` per login; `include-drafts` → `--include-drafts`

The recurring form is `loop` (Recurring mode). If this invocation IS a `/loop` tick whose body re-injects this whole file — the expensive shape — complete the pass normally and, once per session, say so in one line and give the thin body from Recurring mode as the replacement.

## One pass

1. On the first pass of this conversation session only: resolve the repo and check for a watch that died — one Bash call, two commands:

```bash
gh repo view --json nameWithOwner -q .nameWithOwner
bash "<skill-base-dir>/scripts/scan.sh" --status --pidfile .claude/gh-watch-reviews.local.pid
```

`watch_dead` means a watcher was armed here and was killed from outside its own exit paths — almost always because the Claude Code process that owned it went away (restart, crash, quit, or a machine sleep that took the terminal with it). Say so in one line and re-arm it (Watch mode step 2) after this pass completes, subject to the same `ran_for_seconds` rule as step 4's anti-flap. `watch_running` means a watcher is already polling this repo: do the pass, but never arm a second one. `watch_absent` means no watch is meant to be running — do not arm one unless args said `watch`. Then Read `.claude/gh-watch-reviews.local.json`. If the file is absent, this is the first run — read references/setup.md and follow it (interview → write file). Otherwise: if any of `config.review_target`, `config.poll_interval_minutes`, `config.stale_review_hours` is missing (config from an older skill version), ask ONLY for those, in one `AskUserQuestion` call, using the wording in references/setup.md § The interview (questions 4–6), and write the answers into `config` before anything else. Then print exactly one compact line so the user knows what's being watched — with the real `owner/repo`, so resolve it before printing — e.g. `gh-watch-reviews: watching owner/repo · bots excluded · drafts excluded · unrequested PRs on`. Later passes in the same session skip this step entirely — no re-read, no repeated line; a quiet later tick is exactly one tool call (the scanner reads the file itself, and its "state file not found" error is the first-run signal if the file has vanished).
2. Run the scanner — ONE Bash call:

```bash
bash "<skill-base-dir>/scripts/scan.sh" --once
```

3. Act on the JSON `status`:

- `error` (exit 1) → emit exactly one line — `gh-watch-reviews: search failed — <message>` — and stop the pass. Never continue past a failure: a silent "nothing needs review" is the one outcome a watch must never produce from an error. The JSON's `retryable` says which kind it was: `true` is a network or GitHub blip (in watch mode the scanner had already retried it several times before giving up), `false` needs the user — auth above all. It decides whether a watch gets re-armed, see Watch mode step 4.
- `in_review` → a review handed off earlier is still being worked and this tick fired mid-review: **stop silently — produce no output at all.**
- `stale_in_progress` → an `in_progress` entry has held the in-flight lock longer than `config.stale_review_hours` and the scanner could not resolve it from GitHub (no submitted review, PR still open). Quote the returned `held_for_over_hours` — never a number of your own — and ask the user whether that review is genuinely still running; if not, remove the listed entries from `state` (Read → modify → Write) and re-run the pass from step 2.
- `empty` → end the turn with exactly ONE compact heartbeat line and nothing else, using the returned `checked_at` verbatim (never invent, round, or approximate a timestamp): `gh-watch-reviews: owner/repo · no PRs need your review · checked <checked_at>`. This single line IS the entire quiet-tick deliverable — no second line, no summary of what was checked.
- `candidates` → read references/candidates.md and process them as it directs.

## Recurring mode

The cheap way to keep watching. Run step 1 of "One pass" to resolve the repo, then invoke the `loop` skill with **this body verbatim** — substituting only the real skill base directory and the interval (`config.poll_interval_minutes` minutes, or the one given in args):

```
Skill(skill="loop", args="15m Run this and nothing else: bash <skill-base-dir>/scripts/scan.sh --once
Then: if the JSON has a \"line\", reply with exactly that line and nothing else. If \"status\" is \"candidates\" or \"stale_in_progress\", invoke the gh-watch-reviews skill and follow it. Otherwise reply nothing.")
```

Then say in one line what is being watched and how often, and stop.

Why the body is shaped like that, so nobody "improves" it into something expensive:

- **The scanner returns `line`, ready to print.** A quiet tick is one Bash call and one echo — nothing for you to compose, and no timestamp to round, reformat or invent.
- **This file is not part of the tick.** It loads only when a tick actually has work (`candidates` / `stale_in_progress`). Re-injecting it every tick is what made the old `/loop /gh-watch-reviews` form cost ~4.4k tokens a tick; this one measures ~950.
- **A failed check needs no special handling.** The tick reports it and the next tick retries — which is why this form is immune to the failure that repeatedly killed the background watcher (an overdue scan firing before Wi-Fi is back after the machine wakes).

Its one limit: the schedule is in-memory and belongs to the session that created it, so closing Claude Code ends it and it has to be set up again. Nothing polls while no session is running — which is also true of `watch`, and costs nothing real, since no review can happen then either.

## Watch mode

`watch` runs the same scanner as a background loop, which polls without involving the session at all. Prefer Recurring mode unless you specifically want that: this harness kills long-running background commands after about 30 minutes, so a watcher has to be re-armed roughly twice an hour, and each re-arm costs more context (~3.7k tokens, measured) than the ~950 a loop tick costs. Watch only comes out ahead when the poll interval is well under half the kill window — at 5-minute polls it is six polls per re-arm, at 15 it is two, at 30 it is none.

1. Run step 1 above. If `--status` reported `watch_running`, say so and stop — never arm a second one.
2. Launch the scanner with `run_in_background` (no `--once`):

```bash
bash "<skill-base-dir>/scripts/scan.sh" --interval <seconds> --log .claude/gh-watch-reviews.local.log --pidfile .claude/gh-watch-reviews.local.pid
```

`<seconds>` comes from the `watch` argument if it had one, else `config.poll_interval_minutes × 60`. On a re-arm, reuse the interval the dead watcher was running with — it is in the pidfile (`interval`) and in the config; never silently fall back to the default, since a cadence the user chose must survive the restart that killed the watcher. The staleness threshold needs no flag: the scanner reads `config.stale_review_hours` itself, on every scan, so a change to it applies without re-arming.

3. Tell the user in one line that the watch is armed and where the heartbeat log lives, then end the turn. The script polls quietly (heartbeats go to the log, not the session) and runs indefinitely — it exits on its own only for: candidates found (exit 0), search/auth error (exit 1), a stale `in_progress` entry (exit 4), or the session having gone away (exit 0, silent).
4. When a notification for that background task arrives, act on it by what it says:

- A **result JSON** (candidates / error / stale) → handle exactly as in "One pass" step 3, then: after a `candidates` pass finishes, re-arm (step 2). On exit 4 resolve the stale entry ("One pass" step 3), then re-arm. On exit 1, `retryable` decides:
  - `retryable: true` → the network was down long enough that the scanner exhausted its own retries, but by the time you read this it usually isn't (check: `gh auth status` reaching GitHub is proof). Say what failed in one line **and re-arm once**. If the re-armed watcher exits `retryable: true` again, stop and hand it to the user — that is an outage, not a blip.
  - `retryable: false` → auth, a broken state file, a bad flag. **Never re-arm**; surface the message and what it needs (`gh auth login` for auth). Re-arming here would spin forever against a problem only the user can fix.
- **`killed` / `stopped`, or any notification whose output file is empty** → the watcher did not choose to stop; something outside it ended the process. A Claude Code restart is the usual cause (its background children die with it, too fast for the orphan check), so this also arrives as the orphan-summary batch on the next session's first turn. Confirm with `--status` ("One pass" step 1) and, on `watch_dead`, **re-arm immediately** (step 2) — one line saying the watcher was killed and re-armed, nothing more. A dead watch that reports itself dead and then does nothing is the failure this skill exists to prevent. On `watch_absent` do not re-arm: the pidfile is gone because the watch ended deliberately.
- Anti-flap, decided by `--status`'s `ran_for_seconds` (how long the dead watcher polled before it died), never by a count of re-arms: **≥ 600s means it was working and something outside killed it — re-arm, every time, without limit.** External kills are routine here (a Claude Code restart, a reaper, a machine sleep) and they say nothing about the watch being broken; capping re-arms would quietly restore exactly the silent-dead-watch failure this skill exists to prevent. **Under 600s is a watcher that could not stay up**: re-arm it once, and if the replacement also dies under 600s, stop — report both run lengths and the last error in the log, and let the user decide. Two short lives in a row is a fault; a hundred long ones is just a busy machine. `null` means the pidfile predates poll stamping and the run length is unknowable — treat it as healthy and re-arm; the replacement will report a real number.

## Notes

- Two watchers (or a watcher plus a `/loop`) on the same repo are unsupported — the state file has no locking; last write wins. `--status` is the guard: check it before arming.
- A watch cannot poll while Claude Code is not running — the watcher is a child process, not a daemon. What it guarantees is that the watch resumes by itself the moment a session is alive again, which is also all that matters: nothing can be reviewed while the machine is asleep. If the user wants polling that continues with no session at all, that is a launchd agent, not this skill.
- Ad-hoc args never persist; only the setup interview writes `config`.
- State semantics, the interview, and candidate handling live in references/ — read them when the pass needs them, not preemptively.
