# claude-code-reviewer

Automatic PR/MR code reviews powered by Claude Code CLI. Clone, run setup, and every open pull request or merge request assigned to you gets reviewed automatically.

Uses the [gstack](https://github.com/garrytan/gstack) two-pass review methodology by default — CRITICAL issues (SQL safety, race conditions, injection) block, INFORMATIONAL issues (dead code, test gaps, performance) are noted but non-blocking.

Works with **GitHub** and **GitLab**. Zero config beyond `./setup.sh`.

## Quickstart

```bash
git clone https://github.com/yourname/claude-code-reviewer.git
cd claude-code-reviewer
./setup.sh
```

That's it. Setup detects your platform, authenticates, installs a scheduler, and starts reviewing.

## How It Works

```
Every 15 min (configurable):

  review.sh runs
      │
      ├── Detects platform (GitHub / GitLab)
      ├── Fetches open PRs/MRs where you're reviewer
      │
      └── For each PR/MR:
            ├── Skip if already reviewed (checked in reviewed-prs.txt)
            ├── Skip if too many files (> MAX_FILES)
            │
            ├── [gstack mode — default]
            │     ├── Shallow-clone repo to temp dir
            │     ├── Checkout PR/MR branch
            │     ├── Fetch Greptile bot comments (GitHub, if enabled)
            │     ├── Run `claude -p` with full repo context
            │     │     ├── git fetch + git diff for fresh diff
            │     │     ├── Read source files for context (Read/Grep/Glob)
            │     │     ├── Two-pass review (CRITICAL → INFORMATIONAL)
            │     │     ├── Triage Greptile comments (classify + reply)
            │     │     └── Post inline comments + summary
            │     └── Clean up temp clone
            │
            ├── [builtin mode]
            │     ├── Fetch diff via API
            │     └── Pipe diff + checklist to `claude -p`
            │
            └── Mark as reviewed
```

Claude posts comments directly on your PRs/MRs using `gh` or `glab` CLI commands.

## Prerequisites

| Tool | Install |
|------|---------|
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | `npm install -g @anthropic-ai/claude-code` |
| [jq](https://jqlang.github.io/jq/) | `brew install jq` or `apt install jq` |
| [gh](https://cli.github.com/) (GitHub) | `brew install gh` then `gh auth login` |
| [glab](https://gitlab.com/gitlab-org/cli) (GitLab) | `brew install glab` then `glab auth login` |

You need `claude` + `jq` + at least one of `gh`/`glab`.

## Configuration

Edit `config.env` after setup (or re-run `./setup.sh`):

| Variable | Default | Description |
|----------|---------|-------------|
| `PLATFORM` | `auto` | `auto`, `github`, or `gitlab` |
| `USERNAME` | auto-detected | Your platform username |
| `POLL_INTERVAL` | `900` | Seconds between poll cycles (900 = 15 min) |
| `CLAUDE_MODEL` | _(default)_ | `sonnet`, `haiku`, or `opus` |
| `REVIEW_TOOL` | `gstack` | `gstack` (clone + two-pass) or `builtin` (diff-only) |
| `REVIEW_ROLE` | `reviewer` | `reviewer`, `assignee`, or `author` |
| `GREPTILE_TRIAGE` | `true` | Triage Greptile bot comments on GitHub PRs |
| `MAX_FILES` | `100` | Skip PRs with more changed files |
| `MAX_PRS_PER_RUN` | `10` | Max PRs to review per cycle |
| `LOG_MAX_LINES` | `5000` | Auto-trim log to this length |

## Review Modes

### gstack (default)

Based on [garrytan/gstack](https://github.com/garrytan/gstack). For each PR/MR:

1. **Shallow-clones** the repo to a temp directory
2. **Checks out** the PR/MR branch — Claude has full source context, not just the diff
3. **Two-pass review** using the checklist:
   - **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions, Injection & Trust Boundaries
   - **Pass 2 (INFORMATIONAL):** Conditional Side Effects, Dead Code, Test Gaps, Performance, etc.
4. CRITICAL issues → "Request changes". Only INFORMATIONAL → "Approve with comments"
5. Cleans up the temp clone

Falls back to builtin mode automatically if the clone fails.

In gstack mode, Claude has access to `Read`, `Grep`, and `Glob` tools for exploring source files beyond the diff — enabling full-context reviews.

### builtin

Lighter mode — fetches the diff via API and pipes it directly to Claude. No cloning. Faster but Claude only sees the diff, not surrounding source code.

Set `REVIEW_TOOL=builtin` in `config.env` to use this mode.

## Greptile Integration (GitHub only)

If you use [Greptile](https://greptile.com) for automated code review, claude-code-reviewer will automatically triage Greptile bot comments on your PRs:

- **Fetches** all `greptile-apps[bot]` comments (line-level + top-level)
- **Classifies** each as: VALID (include in findings), ALREADY FIXED (auto-reply), or FALSE POSITIVE (reply explaining why)
- **Maintains suppression history** at `~/.gstack/greptile-history.md` — known false positives are skipped in future reviews
- **Replies** to Greptile comments directly on the PR

Disable with `GREPTILE_TRIAGE=false` in `config.env`. GitLab MRs skip Greptile integration automatically.

## Customizing the Review Checklist

Edit `checklist.md` to add your own rules. The file is injected into every review prompt. The default checklist uses gstack's two-pass structure. You can:

- Add language-specific rules (e.g., Go error handling, React hooks rules)
- Move categories between CRITICAL and INFORMATIONAL
- Add project-specific conventions
- Edit the suppressions list (things to NOT flag)

## Manual Usage

```bash
# Run a review cycle manually
./review.sh

# Check what's been reviewed
cat reviewed-prs.txt

# Watch the log
tail -f review.log
```

## Re-reviewing a PR/MR

Remove its URL from `reviewed-prs.txt` and run `./review.sh`:

```bash
# Remove a specific PR
grep -v "github.com/org/repo/pull/42" reviewed-prs.txt > tmp && mv tmp reviewed-prs.txt

# Re-review everything
> reviewed-prs.txt
```

## Changing Poll Interval

1. Edit `POLL_INTERVAL` in `config.env`
2. Re-run `./setup.sh` to update the scheduler (or update manually)

**macOS**: Updates the launchd plist
**Linux**: Updates the crontab entry

## Uninstall

```bash
./uninstall.sh
```

Removes the scheduler (launchd plist or crontab entry). Optionally removes config and state files.

## Troubleshooting

**"config.env not found"**
Run `./setup.sh` first, or copy `config.example.env` to `config.env` manually.

**"claude CLI not found"**
Install Claude Code: `npm install -g @anthropic-ai/claude-code`

**"Cannot auto-detect platform"**
Install and authenticate `gh` or `glab`, or set `PLATFORM` in `config.env`.

**Reviews not posting comments**
Check `review.log` for errors. Common causes:
- Auth token expired — re-run `gh auth login` or `glab auth login`
- Insufficient permissions — ensure your token has PR/MR comment access

**Nested session errors**
The script unsets `CLAUDECODE` to prevent conflicts. If you still see issues, ensure you're not running `review.sh` from within a Claude Code session.

**Log file growing large**
The log auto-trims to `LOG_MAX_LINES` (default 5000) after each run. Reduce this value in `config.env` if needed.

## FAQ

**How much does this cost?**
Each review is one Claude Code CLI invocation. Cost depends on diff size and your Claude plan. Small PRs typically use minimal tokens.

**Can I use a specific model?**
Set `CLAUDE_MODEL` in `config.env` to `sonnet` (fast/cheap), `haiku` (fastest), or `opus` (most thorough).

**Will it review the same PR twice?**
No. Each reviewed PR/MR URL is saved to `reviewed-prs.txt` and skipped on subsequent runs.

**Does it work with GitHub Enterprise / self-hosted GitLab?**
Yes, as long as `gh` or `glab` is configured to point to your instance.

**Can I review PRs I authored?**
Set `REVIEW_ROLE=author` in `config.env` for self-review.

**What's the difference between gstack and builtin mode?**
gstack (default) clones the repo so Claude can read full source files for context — fewer false positives, better understanding of the codebase. builtin mode only sends the diff — faster and lighter, but Claude can't see surrounding code.

**Why does gstack mode clone the repo every time?**
Each clone is shallow (--depth=50) and goes to a temp directory that's cleaned up after review. This ensures Claude always sees the latest code without maintaining local checkouts.

## Credits

Review methodology based on [gstack](https://github.com/garrytan/gstack) by Garry Tan.

## License

MIT
