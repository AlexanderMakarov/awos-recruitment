# GitLab operations — pr-review (public mode)

> **Part of:** [pr-review](../SKILL.md). The GitLab commands for **public mode** (reviewing a real GitLab merge request), keyed by the same operation names as [github.md](github.md) — so the SKILL workflow stays platform-agnostic and only this file changes. Local mode uses [local.md](local.md) instead and runs none of these — it never invokes `glab` or posts to the platform.

## Terminology

GitLab's model differs from GitHub's in names more than in substance. Throughout the SKILL body, read:

| SKILL says | GitLab means |
|---|---|
| PR, `<NUM>` | merge request (MR), its `iid` (the per-project number in the URL, **not** the global `id`) |
| `<OWNER>/<REPO>` | the project path, possibly nested (`group/subgroup/project`); URL-encoded as `$PROJECT` for API calls |
| pending review draft | the MR's set of **draft notes** — per-author, unpublished, published together |
| review comment thread | **discussion** (`discussion_id`); a top-level comment is a discussion with `individual_note: true` |
| summary body | the `note` passed to `bulk_publish` at submit time |
| verdict | `reviewer_state` on `bulk_publish` (`reviewed` / `requested_changes`), or a separate approve call |

Set these once and reuse them in every recipe below:

```sh
PROJECT=$(printf %s '<GROUP>/<PROJECT>' | jq -sRr @uri)   # nested paths encode to group%2Fsub%2Fproject
IID=<MR_IID>
```

For a self-managed instance, add `--hostname <host>` to every `glab api` call (or run inside a clone of that instance's repo, where `glab` picks the host up from the git remote).

## Transport: glab first, MCP as fallback

**Use `glab`.** Every recipe here is a `glab` command, and `glab api` covers what the porcelain doesn't. Prefer it whenever `glab auth status` succeeds.

**Fall back to a GitLab MCP server only if `glab` is missing or unauthenticated.** Do not hardcode MCP tool names — GitLab MCP servers differ widely in which operations they expose. Instead: list the connected GitLab server's tools, map them onto the operation names in this file, and use the match. Read operations (`fetch-pr-context`, `fetch-existing-comments`) are usually covered; draft notes usually are not.

**Never silently skip an operation with no MCP tool.** If the fallback can't perform an operation, say which one and stop — for `create-draft-review` specifically, that means draft delivery is unavailable and the step 5 gate must be adapted (see `preflight`). A review that posts nothing is a failure the user needs to hear about, not a quiet no-op.

## preflight

```sh
glab auth status                            # bail with "run glab auth login" if not authed
ME=$(glab api user | jq -r .username)       # to detect your own prior notes and draft notes
```

(`glab api` has no `--jq` flag — pipe through `jq`. `glab mr view` does have `--jq`.)

You're reviewing someone else's MR — don't check out the branch or modify project files. Read the diff through the API. (The one write allowed is the skill's own draft artifact in `review/` — that's your output, not the project's code.)

### Draft-notes capability probe — run this here, before any analysis

Unlike GitHub, draft delivery on GitLab can be unavailable on a given instance or token, and the step 5 results gate needs to know **before** it asks the user how to proceed. Probe once:

```sh
glab api "projects/$PROJECT/merge_requests/$IID/draft_notes" >/dev/null 2>&1 && DRAFTS=yes || DRAFTS=no
```

If the exit status is ambiguous, re-run with `-i` and read the HTTP status line — a 404 and a 403 mean different things (see Failure modes) and the user can act on the difference.

The Draft Notes API is Free-tier and available on GitLab.com, Self-Managed and Dedicated, so `DRAFTS=yes` is the normal case. `DRAFTS=no` means an instance too old for the endpoint, a token without the scope, or an MCP-only fallback with no draft tool.

Carry the result into step 5:

- **`DRAFTS=yes`** — the gate's options are unchanged; delivery creates draft notes the user publishes themselves.
- **`DRAFTS=no`** — **there is no draft delivery on this MR.** Say so in the gate itself and change its options: the only ways to deliver are publishing the discussions now or writing the review to a file and posting nothing. Never present "proceed" as a draft when it would publish — the user is approving publication, and must be told that's what they're approving.

## fetch-pr-context

```sh
glab mr view $IID -R <GROUP>/<PROJECT> -F json --jq '{iid, title, author: .author.username, source_branch, target_branch, web_url}'
glab mr diff $IID -R <GROUP>/<PROJECT>      # the unified diff under review
```

The diff defines the review surface: comment only on lines this MR added or modified.

**Also capture the diff refs now** — every inline comment position needs all three SHAs, and there's no way to anchor a finding without them:

```sh
glab api "projects/$PROJECT/merge_requests/$IID" | jq '.diff_refs'   # {base_sha, start_sha, head_sha}
```

```sh
# Fallback if diff_refs is absent: the newest MR version carries the same three SHAs under different names.
glab api "projects/$PROJECT/merge_requests/$IID/versions" | jq '.[0] | {base_commit_sha, start_commit_sha, head_commit_sha}'
```

Bind them as `BASE_SHA`, `START_SHA`, `HEAD_SHA`. They must come from the MR's **current** head — refetch after any push, or positions will be rejected.

## fetch-existing-comments

Run **before** drafting, so you engage prior threads and never repeat a point someone already made. One paginated call returns every discussion, resolved or not, with the position that anchors it:

```sh
glab api --paginate "projects/$PROJECT/merge_requests/$IID/discussions" | jq -r '
  .[] | . as $d | .notes[0] as $first |
  "\($first.position.new_path // "(no position)"):\($first.position.new_line // "-")  discussion=\($d.id)  resolved=\($first.resolved // false)  \($first.author.username): \($first.body[0:120])"'
```

Each discussion carries `id` (the `<DISCUSSION_ID>` used by `reply-to-thread`), `individual_note`, and `notes[]` with `author.username`, `body`, `created_at`, `resolvable`, `resolved`, and `position`.

Use it to skip points already raised, decide which open threads to agree with or push back on, and detect a re-review. GitLab has **no review object** with a `submittedAt` — a re-review is instead detected from the timestamp of your own most recent published note:

```sh
glab api --paginate "projects/$PROJECT/merge_requests/$IID/notes" \
  | jq -r --arg me "$ME" '[.[] | select(.author.username==$me)] | max_by(.created_at) | .created_at // "none"'
```

If that returns a timestamp, diff against what changed since it.

**Your own prior comments are part of this conversation — surface them first.** A pass you (or the user) already made on this MR is the set most easily duplicated, and "existing comments" reads too easily as "other people's / the bot's". Before scanning what anyone else said, list `$ME`'s own notes explicitly:

```sh
glab api --paginate "projects/$PROJECT/merge_requests/$IID/notes" | jq -r --arg me "$ME" '
  .[] | select(.author.username==$me)
  | "\(.position.new_path // "(no position)"):\(.position.new_line // "-")  note=\(.id)  \(.body[0:100])"'
```

Treat each as a thread to build on, not a line to re-open: if a finding lands on a `path:line` you already commented on, plan a `reply-to-thread` on that existing discussion rather than a second thread. A prior comment may sit in a **resolved** discussion (the author already fixed it) — resolved still means "already raised", so don't re-flag it; at most acknowledge the fix or add a genuinely new angle as a reply.

Who has already approved is separate from the notes, and worth knowing before you draft a verdict:

```sh
glab api "projects/$PROJECT/merge_requests/$IID/approvals" | jq '{approved: .approved, by: [.approved_by[].user.username]}'
```

## find-pending-review

Draft notes are **per-author** — this returns only your own, and they may be the **user's own hand-written drafts**. Always look before delivering:

```sh
glab api "projects/$PROJECT/merge_requests/$IID/draft_notes" | jq -r '
  .[] | "\(.id)  \(.position.new_path // "(no position)"):\(.position.new_line // "-")  \(.note[0:100])"'
```

**Never-destroy rule.** If this returns rows, drafts already exist. Unlike GitHub, GitLab needs no delete-then-recreate — each draft note is created independently, so `create-draft-review` **appends** to the existing set. That makes destruction unnecessary, and therefore forbidden: never call `DELETE .../draft_notes/<id>` without explicit approval.

Do still tell the user what's already there before appending, and confirm — publishing is all-or-nothing (`bulk_publish` publishes *every* pending draft note, including theirs), so your review can't be submitted without carrying their drafts along with it. If they'd rather not mix the two, let them publish or delete their own drafts first.

## create-draft-review

**Default delivery in public mode** when `DRAFTS=yes`. Each finding is one draft note, unpublished until the user publishes them. Post them one call at a time; GitLab's own docs pass the position as bracketed form fields, which is what `glab api --form` sends:

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/draft_notes" \
  --form 'note=<finding, in house style>' \
  --form 'position[position_type]=text' \
  --form "position[base_sha]=$BASE_SHA" \
  --form "position[start_sha]=$START_SHA" \
  --form "position[head_sha]=$HEAD_SHA" \
  --form 'position[old_path]=src/foo.py' \
  --form 'position[new_path]=src/foo.py' \
  --form 'position[new_line]=42'
```

- `new_line` is the line in the MR's head version. For a line that only exists before the change (a deletion), send `position[old_line]` instead; for a line present in both, sending both is safest.
- `old_path` is required even when the file wasn't renamed — set it equal to `new_path`.
- **Multi-line findings degrade to single-line.** GitLab anchors ranges with `position[line_range][start|end][line_code]`, where a line code is a per-file hash the API doesn't hand you directly. Don't fabricate one: anchor the comment at the range's most relevant line and describe the span in the comment text ("lines 10–14 …").

**The summary has no home on a GitLab draft note.** GitHub's pending review carries a `body`; GitLab's draft notes don't. Post the summary as its own **positionless** draft note so the user can see it alongside the inline drafts:

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/draft_notes" \
  --form 'note=<summary + architectural notes, in house style>'
```

`bulk_publish` also accepts a summary at submit time (see below) — but the user, not you, runs the submit, so the positionless draft note is what actually guarantees the summary reaches the MR. Post it either way, and still print the verbatim summary in step 7.

After creating, confirm the drafts landed — re-run `find-pending-review` and check the count matches what you posted, including the summary note. Report the count to the user with the MR URL; GitLab shows pending drafts in the MR's **Changes** tab, and publishing is a button there ("Submit review"), or:

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/draft_notes/bulk_publish"
```

## submit-review

Only when the user explicitly chooses to submit now instead of leaving drafts. `bulk_publish` publishes every pending draft note **and** carries the summary and the verdict:

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/draft_notes/bulk_publish" \
  --form 'note=<summary>' \
  --form 'reviewer_state=requested_changes'
```

`reviewer_state` is `reviewed` or `requested_changes`. Per GitLab's docs it "does not record a formal approval" — approving is a separate call, and it's the one verdict the user must choose explicitly:

```sh
glab mr approve $IID -R <GROUP>/<PROJECT>
```

If `DRAFTS=no`, there is nothing to publish and this operation doesn't apply — the user chose publish-now at the adapted gate, so post each finding as a real discussion instead (same `--form position[...]` fields as `create-draft-review`, against `.../discussions`, with `body=` in place of `note=`), and post the summary with `glab mr note $IID -m '<summary>'`.

## reply-to-thread

When your review engages an existing discussion (agree, build on, or push back), keep the reply **in the draft set** so it publishes atomically with the rest of the review:

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/draft_notes" \
  --form 'note=<reply>' \
  --form 'in_reply_to_discussion_id=<DISCUSSION_ID>'
```

To reply immediately instead (when there are no drafts to keep it with):

```sh
glab api -X POST "projects/$PROJECT/merge_requests/$IID/discussions/<DISCUSSION_ID>/notes" -f body='<reply>'
```

Don't resolve other people's discussions — you're the reviewer, not the author. (A draft note can carry `resolve_discussion=true`; don't use it here.)

## Failure modes

| Symptom | Handling |
|---|---|
| `glab auth status` fails | Bail with "run `glab auth login`" — or, for a self-managed host, `glab auth login --hostname <host>`. |
| Draft-notes probe returns 404 | `DRAFTS=no` — instance predates the endpoint. Adapt the step 5 gate (publish now vs file only); never call it a draft. |
| Draft-notes probe returns 401/403 | `DRAFTS=no` — the token lacks `api` scope (a read-only token can fetch but not draft). Say which, so the user can fix it and retry rather than losing the draft path silently. |
| `find-pending-review` returns rows | Drafts already exist and may be the user's. Append, never delete — and tell them first, since `bulk_publish` will publish theirs too. |
| Draft/discussion POST 400 "Note position is invalid" | The SHAs are stale or the line isn't in the diff. Refetch `diff_refs` and retry once; if it still fails, move the finding into the summary rather than dropping it. |
| Draft/discussion POST 400 on `line_range` | Multi-line anchoring — degrade to a single-line comment and describe the span in the text. |
| `bulk_publish` rejects `reviewer_state=requested_changes` | Not available on this tier or version. Retry with `reviewed` and put the verdict in the summary text. |
| `glab mr approve` → "cannot approve your own merge request" | You're the author; drop the approve and publish with `reviewer_state=reviewed`. |
| A prior published note by `$ME` exists | Re-review: comment only on what changed since its `created_at`; don't re-flag addressed points. |
| MR `iid` vs `id` confusion (404 on a number that exists) | Every endpoint here takes the **iid** — the number in the MR's URL. |
