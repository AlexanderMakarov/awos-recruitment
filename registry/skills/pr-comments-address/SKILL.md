---
name: pr-comments-address
description: Use when working through code-review feedback to apply fixes and replies — "address the PR comments", "address the MR comments", "reply to CodeRabbit/Codex feedback", "resolve these review threads", "apply this review". Works in two modes. Public mode (default) responds to reviewer feedback on a pull request or merge request you authored, on GitHub or GitLab — fix, reply, resolve, commit, and push. Local mode — triggered when the request says "locally", "for myself", "apply this review", or "don't post" — applies feedback from a local review file to your working tree, posting nothing to a review platform. Each item gets a proposed fix or reply for your approval first. This is the author's side; to review someone else's PR, use pr-review.
---

<!-- No `context: fork`: forked skills run as subagents, which cannot use AskUserQuestion — the per-item approval gate this skill is built around. For isolation from other work, invoke this skill in a dedicated session instead. -->

# Address Review Comments

Work through reviewer feedback with technical rigor over social comfort. Verify before implementing, push back when warranted, and never apply a fix or post a reply the user hasn't approved. The user decides; you draft and execute.

## Modes

Decide the mode before starting the workflow, and state it in one line.

- **public** (default): respond to feedback on a PR **you authored**. Fetch unresolved threads and comments, then fix, reply, resolve, commit, and push. Uses the platform reference selected below.
- **local**: apply feedback that lives **on your machine** — a local review file (e.g. one written by pr-review's local mode) or feedback the user pastes. Edit the working tree only; nothing leaves the machine. Use this when the request says "locally", "for myself", "apply this review", "don't post", or points at a review file. Uses [references/local.md](references/local.md).

**Choosing:** if the request signals local (the trigger words above, or names a review file), use local. If it references a PR (URL or `owner/repo#N`), use public. If ambiguous, ask with `AskUserQuestion`, offering Public as the default.

## Platform (public mode)

Resolve the platform before step 1 and state it alongside the mode. Take the first signal that answers:

1. the host in the PR/MR URL the user gave;
2. the host of the repo's `git remote` (`git remote get-url origin`);
3. which CLI is authenticated (`gh auth status` / `glab auth status`).

`github.com` or a GitHub Enterprise host → [references/github.md](references/github.md). `gitlab.com` or a self-managed GitLab host → [references/gitlab.md](references/gitlab.md). If the signals conflict or none resolves, ask with `AskUserQuestion` — never guess, since the wrong reference fetches nothing or replies in the wrong place.

The workflow below is platform-agnostic and names operations (`preflight`, `checkout-pr`, `fetch-working-set`, `reply-to-thread`, `resolve-thread`); the selected reference defines them. It says "PR" throughout — on GitLab read merge request, `<NUM>` as the MR `iid`, and "thread" as discussion. Local mode needs none of this.

Treat automated reviewers (CodeRabbit, Codex, Bito, Sonar, and similar) as suggestions to evaluate, not directives — many of their comments are mechanical and some are confidently wrong. Agreement is earned on the merits.

## Input

`args` is a PR reference (public) or a review-file path / empty (local). Parse what you can; if public mode can't resolve a PR, ask for a PR URL.

## Workflow

```
- [ ] 1. Gather feedback items
- [ ] 2. Triage in a fresh subagent; materialize the plan
- [ ] 3. Results gate: present the plan and ask — back with sources / proceed / change
- [ ] 4. Apply each approved item
- [ ] 5. Commit (public: + push)
- [ ] 6. Summary
```

### 1. Gather feedback items

- **public:** run `preflight`, `checkout-pr`, and `fetch-working-set` from the platform reference (selected above). `checkout-pr` handles the branch: if you're **already on the PR's head branch**, stay put and just pull to the tip — a worktree would be redundant. Otherwise it defaults to an **isolated git worktree**, so the user's current branch and working tree stay untouched — only check the branch out in place if the user asked for that (e.g. they want to review or run it in their main working tree). If the working set is empty, say "Nothing new to address" and stop.
- **local:** run `read-feedback` from [references/local.md](references/local.md) to load the review file or pasted text into discrete items.

### 2. Triage in a fresh subagent

Knowing the work is the author's job; defending it is not. The dangerous judgment here is triage — classifying an item as `fix` vs `pushback` — and a session that wrote or debated the code under feedback is anchored to its own decisions. A model is also a poor judge of its own anchoring, so don't self-assess independence; remove the need for it: triage runs in a **fresh subagent** that never sees this conversation, whether the session touched the code or not.

Collect what the subagent legitimately needs before dispatching. If the request links or references an off-platform discussion — a Slack thread, meeting notes, a roadmap or ticket, a design doc — fetch it now (the subagent may lack access to the tools or auth that reach it); it may show that a point a reviewer raised was already settled elsewhere (making it `pushback` or `dismiss-resolve`) or explain the intent behind a change under question. If reading it fails (no access, dead link, auth wall), don't silently skip it — tell the user and ask them to paste the relevant content, or to confirm you should proceed without it. Pass it to the subagent as source material — verbatim, or an extractive digest of what was said and decided — never as your conclusions about the feedback.

Dispatch one triage subagent with the Agent tool (`subagent_type: "general-purpose"` — a fresh context; **not** `"fork"`, which inherits this conversation and defeats the isolation). Hand it exactly:

- the PR ref and the checkout path from step 1 (local: the repo path and the review file's origin);
- every feedback item verbatim: author, `path:line`, full thread contents (public: include `originalLine` and `diffHunk` for outdated threads where `line` is null);
- the off-platform source material collected above;
- this SKILL.md's path, with the instruction to follow this step's category table and drafting rules and the reply-voice boundaries below.

Withhold everything else — what this session intended, designed, or argued about the change. The urge to add "helpful context" about what the code was meant to do is exactly the anchoring the subagent exists to strip out: the code, the diff, and the reviewer's words are its whole world, so its categorization can't be a defense of decisions it never saw.

The subagent works the items: it `Read`s the file at each comment's `path` around `line` before drafting — never a proposed fix without seeing the code — and for a long list it may fan the reading out to its own nested subagents (collection suits a small/fast model; categorizing and drafting stay in the one triage context so replies sound like one author). For each item it returns the category, the actual reply text, and — for a `fix` — a one-line description of the code change. Not placeholders. Categorize each item:

| Category | When | Action |
|---|---|---|
| `fix` | A real bug or valid improvement | Edit the code and (public) reply explaining the change. Don't resolve — leave that for the reviewer. |
| `pushback` | Wrong, missing context, YAGNI, or conflicts with a deliberate decision | (public) Reply with reasoning, don't resolve. (local) Record the reasoning for the user. |
| `dismiss-resolve` | A mechanical nit with nothing for a human to confirm | (public) Short reply, then resolve. (local) Note it and skip. |
| `clarify` | Ambiguous | (public) Reply with a specific question. (local) Record the question. |

**Materialize the returned plan with `Write`** to the repo's `review/` folder (create it if missing — and when you create the folder, tell the user it's new so they decide what to do with it; don't gitignore it automatically, since a persisted review trail can be intentional): `review/pr-<N>-comments-plan.md`. A plan that exists only in the subagent's reply or in thinking does not exist for the gate — the `Write` call is the verifiable proof it does, and an in-repo file is one the user can open in their editor no matter what happens to the chat. Record the plan as the subagent returned it: if you disagree with a categorization, don't silently reclassify — the disagreement is itself session knowledge — add a marked note (`session note: …`) to that item and let the user rule at the gate.

If agent dispatch is unavailable (rare — e.g. this skill is already running at the subagent nesting depth limit): triage inline with the discipline the subagent would have applied — judge each item from the code and the reviewer's argument as they stand, restate the reviewer's point in its strongest form before classifying anything `pushback` — and carry a one-line independence caveat into the step 6 summary (never into posted replies).

### 3. Results gate

Present the plan **as message text**, numbered and scannable — every item with its category, `path:line`, author, and the actual proposed fix and reply text, not placeholders. The user can only approve what they can read: if the plan isn't in the message, the gate is void. Any session-wide brevity or compression mode governs your commentary, never the plan — a file path or a recap does not satisfy this step.

**Pre-gate protocol — the plan is the step 2 file, not your memory.** Present it by printing the file's full content as message text, then call `AskUserQuestion` — and always include the file path in the question itself, so the user can reach the plan even if the print gets squeezed out. The documented failure here: composing the plan in thinking, then gating on "the plan is above" while the message contains nothing — your memory of having printed is not evidence; only the `Write` call and text visible in this turn are. If there is no plan file, you have no plan: go back and write it. Then ask the user how to proceed:

- **Proceed** — apply the plan as-is.
- **Back findings with external sources** — before applying, verify the contestable items against a trusted source (official docs, the spec, a high-signal StackOverflow or GitHub issue, or — for an architectural claim about how the system fits together — the project's own sibling repos and artifacts, not just external docs), cite it in the fix/reply, and drop or downgrade items that don't hold up. Then re-present the revised plan and return to this gate — don't apply until the user picks Proceed.
- **Change something** — take the user's edits (apply some plan items, skip others, reword a reply — whatever the user directs), restate, and confirm.

Apply, reply, or resolve nothing before the user picks Proceed.

### 4. Apply each approved item

- **public:** per item — `Edit` for a `fix`; reply via `reply-to-thread` or `reply-to-top-level`; resolve via `resolve-thread` only for `dismiss-resolve`. Never resolve a `fix`, `pushback`, or `clarify` thread.
- **local:** follow `apply-locally` in [references/local.md](references/local.md) — `Edit` for fixes; record pushback/clarify reasoning in the summary. No replies, no resolves.

### 5. Commit

Group changes into logically coherent commits. The subject describes the substance, not the comment (`fix(billing): jitter webhook retry backoff`, not `address review comment`). Match the project's commit style. If a pre-commit hook fails, fix the cause and make a new commit — never `--amend` or `--no-verify`.

- **public:** `git push` (skip if nothing was committed). Never push to a branch other than the PR's head branch; never force-push.
- **local:** commit only if the user asked; never push.

### 6. Summary

Report fixes (with commit hashes), replies and their state (public), recorded pushback/clarify notes (local), and skipped items. End with the PR URL on its own line in public mode.

## Boundaries

- Never edit code, post a reply, or resolve a thread the user hasn't approved at the results gate.
- Hand the triage subagent only the PR ref, the feedback items, the code, and off-platform source material — never this session's reasoning, intent, or debate about the change, and never a fork that inherits it.
- Never resolve a `fix`, `pushback`, or `clarify` thread — only `dismiss-resolve` (public).
- In public mode: never push to a branch other than the PR's head branch; never `--amend`, `--force`, or `--no-verify` unless the user explicitly asks.
- In local mode: stay on the working tree, never post to or contact a review platform, and never push — surfacing changes to a remote is the user's call.
- No performative replies ("Great catch!", "You're absolutely right!"). State the technical fact or the next step.
- Session-wide brevity or compression modes never shrink a deliverable: the step 3 plan and step 6 summary print in full as message text.
- If the user asks to address one item and leave the rest, do exactly that.
