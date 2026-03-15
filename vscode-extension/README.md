# Claude Code Reviewer — VS Code Extension

Review GitHub PRs and GitLab MRs directly from VS Code using Claude Code CLI.

## Quick Start

1. Install from the [VS Code Marketplace](https://marketplace.visualstudio.com/items?itemName=shubhesh07.claude-code-reviewer) (search "Claude Code Reviewer")
2. Open Command Palette (`Cmd+Shift+P`) → `Claude: Review Current PR`
3. That's it — the extension auto-installs the CLI tool on first use

## Features

- **Auto-Install** — prompts to install the CLI tool automatically if not found
- **Review Current PR** — detects the PR/MR for your current branch and reviews it
- **Review by URL** — paste any GitHub PR or GitLab MR URL to review
- **Status Bar** — one-click access from the bottom bar
- **Streaming Output** — watch the review progress in real-time
- **Smart Detection** — finds `review.sh` automatically even in non-standard locations

## Prerequisites

The extension auto-installs the [claude-code-reviewer](https://github.com/shubhesh07/claude-code-reviewer) CLI on first run. You just need:

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code): `npm install -g @anthropic-ai/claude-code`
- [gh](https://cli.github.com/) (GitHub): `brew install gh` then `gh auth login`
- [glab](https://gitlab.com/gitlab-org/cli) (GitLab): `brew install glab` then `glab auth login`

## Usage

- **Command Palette** (`Cmd+Shift+P`) → `Claude: Review Current PR` or `Claude: Review PR by URL`
- **Status Bar** → click "Claude Reviewer" in the bottom bar

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `claude-reviewer.reviewShPath` | auto-detected | Path to `review.sh` (leave empty for auto-detect) |
| `claude-reviewer.platform` | `auto` | `auto`, `github`, or `gitlab` |

## How It Works

The extension wraps the [claude-code-reviewer](https://github.com/shubhesh07/claude-code-reviewer) CLI tool. When you run a review:

1. Detects your current branch's PR/MR (or uses the URL you provided)
2. Runs `review.sh` which invokes Claude Code with full repo context
3. Claude performs a two-pass review (CRITICAL + INFORMATIONAL)
4. Posts inline comments on the exact lines where issues are found
5. Posts a summary comment with the overall verdict

## Links

- [GitHub](https://github.com/shubhesh07/claude-code-reviewer)
- [Report Issues](https://github.com/shubhesh07/claude-code-reviewer/issues)
- [JetBrains Plugin](https://plugins.jetbrains.com/plugin/30706-claude-code-reviewer)
