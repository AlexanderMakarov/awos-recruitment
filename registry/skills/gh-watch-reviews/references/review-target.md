# Launching a review in a separate session

Goal: run the review in its own TUI session so its transcript doesn't interleave with the watch session (or with other reviews). The new session must start in the watched repo's directory and run:

```bash
claude "/pr-review <PR URL>"
```

## Picking the surface — first match wins

Detect with `command -v <tool>` / the environment variables noted below; use the first one present.

1. **cmux** (`command -v cmux`) — verified syntax:

```bash
cmux new-workspace --name "pr-<number>" --cwd "<watched repo path>" --command 'claude "/pr-review <PR URL>"' --focus false
```

2. **tmux** (`$TMUX` set):

```bash
tmux new-window -d -n "pr-<number>" -c "<watched repo path>" 'claude "/pr-review <PR URL>"'
```

3. **Any other terminal manager the user runs** (zellij, kitty, wezterm, herdr, iTerm2, …) — discover its syntax, never guess it:
   1. `command -v <tool>` to confirm it's installed, then read `<tool> --help` (and the relevant subcommand's `--help`) for a "new tab/pane/window running a command" invocation. Likely candidates to look for: `zellij run --name … --cwd … -- <cmd>`, `kitty @ launch --type=tab --cwd … <cmd>`, `wezterm cli spawn --cwd … -- <cmd>`.
   2. If the local help doesn't settle it, check the tool's own docs (its GitHub repo / website — e.g. herdr is the agent multiplexer at herdr.dev) via WebFetch/WebSearch.
   3. Only run a command whose meaning you confirmed in step 1 or 2. If you can't confirm one, fall through to 4.

4. **Fallback (nothing detected or confirmed)** — don't launch anything. Print the exact command for the user to run in any terminal:

```
cd <watched repo path> && claude "/pr-review <PR URL>"
```

The state entry is already `in_progress`, so the watch won't re-surface the PR while they get to it.

## Completion tracking

A separate session never writes this repo's watch state. That's fine: the scanner resolves `in_progress` entries against GitHub on every scan — a review you submitted after the entry's timestamp flips it to `reviewed`, a closed/merged PR prunes it.

Nothing here watches the launched session itself. Whether that tab is still open, still running `claude`, or was closed an hour ago is invisible to the scanner — GitHub is its only source of truth, and an abandoned review looks exactly like a slow one. That is what `config.stale_review_hours` is for: if an external review neither gets submitted nor closed within that window, the scanner reports `stale_in_progress` and the watch session asks the user what happened instead of staying paused.
