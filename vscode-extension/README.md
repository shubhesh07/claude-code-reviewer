# Claude Code Reviewer — VS Code Extension

Review GitHub PRs and GitLab MRs directly from VS Code using Claude Code CLI.

## Features

- **Review Current PR** — Detects the PR/MR for your current branch and reviews it
- **Review by URL** — Paste any PR/MR URL to review it
- **Status Bar** — One-click access to review from the status bar
- **Streaming Output** — Watch the review progress in real-time

## Prerequisites

1. Install [claude-code-reviewer](https://github.com/shubhesh07/claude-code-reviewer):
   ```bash
   git clone https://github.com/shubhesh07/claude-code-reviewer.git ~/claude-code-reviewer
   cd ~/claude-code-reviewer && ./setup.sh
   ```

2. Ensure `claude`, `jq`, and `gh`/`glab` CLI are installed and authenticated.

## Usage

- **Command Palette** → `Claude: Review Current PR` or `Claude: Review PR by URL`
- **Status Bar** → Click "Claude Reviewer" in the bottom bar

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `claude-reviewer.reviewShPath` | auto-detected | Absolute path to `review.sh` |
| `claude-reviewer.platform` | `auto` | `auto`, `github`, or `gitlab` |

## Install from VSIX

```bash
cd vscode-extension
npm install && npm run compile
npm run package
code --install-extension claude-code-reviewer-0.1.0.vsix
```
