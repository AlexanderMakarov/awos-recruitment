---
name: gh-watch-reviews
description: Use when the user wants to watch the current GitHub repo for pull requests that need their review — new PRs, explicit review requests, re-requests after new commits — e.g. "watch for incoming reviews", "check PRs needing my review", or to set up a recurring check. GitHub-only (gh CLI). Not for reviewing one specific known PR (invoke pr-review directly).
argument-hint: "[loop [interval] | reconfigure | exclude: <login>, ... | include-drafts]"
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
- `loop [interval]` → set up the recurring check (see Recurring mode). `interval` accepts whole minutes or hours (`5m`/`15m`/`1h`; one minute is the floor, since the schedule's granularity is a minute) and overrides `config.poll_interval_minutes` for this invocation only
- `reconfigure` → re-run the config interview (references/setup.md), keep `state` untouched, then do a normal pass
- ad-hoc overrides, applied to this invocation only: `exclude: <login>[, <login>…]` → `--exclude <login>` per login; `include-drafts` → `--include-drafts`

The recurring form is `loop` (Recurring mode). If this invocation IS a `/loop` tick whose body re-injects this whole file — the expensive shape — complete the pass normally and, once per session, say so in one line and give the thin body from Recurring mode as the replacement.

## One pass

1. On the first pass of this conversation session only: resolve the repo (`gh repo view --json nameWithOwner -q .nameWithOwner`) and Read `.claude/gh-watch-reviews.local.json`. If the file is absent, this is the first run — read references/setup.md and follow it (interview → write file). Otherwise: if any of `config.review_target`, `config.poll_interval_minutes`, `config.stale_review_hours` is missing (config from an older skill version), ask ONLY for those, in one `AskUserQuestion` call, using the wording in references/setup.md § The interview (questions 4–6), and write the answers into `config` before anything else. Then print exactly one compact line so the user knows what's being watched — with the real `owner/repo`, so resolve it before printing — e.g. `gh-watch-reviews: watching owner/repo · bots excluded · drafts excluded · unrequested PRs on`. Later passes in the same session skip this step entirely — no re-read, no repeated line; a quiet later tick is exactly one tool call (the scanner reads the file itself, and its "state file not found" error is the first-run signal if the file has vanished).
2. Run the scanner — ONE Bash call:

```bash
bash "<skill-base-dir>/scripts/scan.sh" --once
```

3. Act on the JSON `status`:

- `error` (exit 1) → emit exactly one line — `gh-watch-reviews: search failed — <message>` — and stop the pass. Never continue past a failure: a silent "nothing needs review" is the one outcome a watch must never produce from an error. The JSON's `retryable` says which kind it was: `true` is a network or GitHub blip — the next scheduled tick will simply try again, so say what failed and stop; `false` needs the user (auth above all), so say what it needs.
- `in_review` → a review handed off earlier is still being worked and this tick fired mid-review: **stop silently — produce no output at all.**
- `stale_in_progress` → an `in_progress` entry has held the in-flight lock longer than `config.stale_review_hours` and the scanner could not resolve it from GitHub (no submitted review, PR still open). Quote the returned `held_for_over_hours` — never a number of your own — and ask the user whether that review is genuinely still running; if not, remove the listed entries from `state` (Read → modify → Write) and re-run the pass from step 2.
- `empty` → end the turn with exactly ONE compact heartbeat line and nothing else, using the returned `checked_at` verbatim (never invent, round, or approximate a timestamp): `gh-watch-reviews: owner/repo · no PRs need your review · checked <checked_at>`. This single line IS the entire quiet-tick deliverable — no second line, no summary of what was checked.
- `candidates` → read references/candidates.md and process them as it directs.

Independently of `status`, if the JSON carries **`check_stale: true`**, a recurring check was set up in this repo and has not run for more than twice its interval — almost always because the session that owned it was closed, since the schedule lives in memory and leaves nothing behind. Add exactly one line after whatever the status called for, quoting the returned values: `gh-watch-reviews: recurring check (every <check_interval_minutes>m) hasn't run since <check_last_at> — say "loop" to start it again`. It is the one case where a quiet pass gets a second line, because silence from a check that stopped is indistinguishable from silence meaning "nothing to review" — which is the failure this skill exists to prevent.

## Recurring mode

The cheap way to keep watching. Run step 1 of "One pass" to resolve the repo, then invoke the `loop` skill with **this body verbatim** — substituting only the real skill base directory and the interval (`config.poll_interval_minutes` minutes, or the one given in args):

```
Skill(skill="loop", args="15m Run this and nothing else: bash <skill-base-dir>/scripts/scan.sh --once
Then: if the JSON has a \"line\", reply with exactly that line and nothing else. If \"status\" is \"candidates\" or \"stale_in_progress\", invoke the gh-watch-reviews skill and follow it. Otherwise reply nothing.")
```

Then record that a check is meant to be running here — one Bash call — and say in one line what is being watched and how often:

```bash
bash "<skill-base-dir>/scripts/scan.sh" --mark-armed <interval in whole minutes>
```

Without it nothing survives the session: the schedule is in memory, so once this session closes, a check that stopped looks exactly like one that was never set up. Every scan stamps the marker, so a running check stays fresh by itself.

Why the body is shaped like that, so nobody "improves" it into something expensive:

- **The scanner returns `line`, ready to print.** A quiet tick is one Bash call and one echo — nothing for you to compose, and no timestamp to round, reformat or invent.
- **This file is not part of the tick.** It loads only when a tick actually has work (`candidates` / `stale_in_progress`). Re-injecting it every tick is what made the old `/loop /gh-watch-reviews` form cost ~4.4k tokens a tick; this one measures ~950.
- **A failed check needs no special handling.** The tick reports it and the next tick simply runs — which is why this form shrugs off the scan that fires after the machine wakes, before Wi-Fi is back.

Its one limit: the schedule is in-memory and belongs to the session that created it, so closing Claude Code ends it and it has to be set up again.

## Notes

- Two recurring checks on the same repo are unsupported — the state file has no locking; last write wins.
- Nothing checks while Claude Code is not running, and nothing here is a daemon. That costs nothing real — no review can happen then either. Polling that continues with no session at all is a launchd agent, not this skill.
- Ad-hoc args never persist; only the setup interview writes `config`.
- State semantics, the interview, and candidate handling live in references/ — read them when the pass needs them, not preemptively.
