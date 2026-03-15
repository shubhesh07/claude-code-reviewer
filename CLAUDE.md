# claude-code-reviewer — CLAUDE.md

## Project Overview
Open-source auto PR/MR code review tool powered by Claude Code CLI. Detects platform (GitHub/GitLab), polls for open PRs/MRs, and reviews them using the gstack two-pass methodology (CRITICAL blocks, INFORMATIONAL noted).

**GitHub**: https://github.com/shubhesh07/claude-code-reviewer
**VS Code Marketplace**: https://marketplace.visualstudio.com/items?itemName=shubhesh07.claude-code-reviewer
**JetBrains Marketplace**: https://plugins.jetbrains.com/plugin/30706-claude-code-reviewer

## Repo Structure
```
claude-code-reviewer/
├── review.sh              # Main review script (~1220 lines) — polling + direct URL review
├── setup.sh               # Interactive setup (--auto flag for non-interactive)
├── uninstall.sh           # Clean removal (launchd/crontab)
├── config.example.env     # Template config
├── checklist.md           # Two-pass review checklist (CRITICAL + INFORMATIONAL)
├── README.md              # Documentation
├── CLAUDE.md              # This file
├── vscode-extension/      # VS Code extension (TypeScript)
│   ├── package.json
│   ├── src/
│   │   ├── extension.ts
│   │   ├── commands/      # reviewCurrentPr.ts, reviewByUrl.ts
│   │   ├── services/      # prDetector.ts, reviewRunner.ts
│   │   └── utils/         # config.ts
│   └── README.md
├── jetbrains-plugin/      # GoLand/IntelliJ plugin (Kotlin)
│   ├── build.gradle.kts
│   ├── gradle.properties
│   ├── settings.gradle.kts
│   ├── gradlew / gradlew.bat
│   └── src/main/
│       ├── resources/META-INF/plugin.xml
│       └── kotlin/com/claudereviewer/
│           ├── action/    # ReviewCurrentPrAction.kt, ReviewByUrlAction.kt
│           ├── service/   # PrDetector.kt, ReviewRunner.kt
│           └── toolwindow/# ReviewToolWindowFactory.kt
└── googleaa18bbe893ad7c12.html  # Google Search Console verification
```

## Branches
- `main` — stable release (CLI tool + setup + README)
- `feat/vscode-extension` — VS Code extension (published to marketplace)
- `feat/goland-plugin` — GoLand/IntelliJ plugin (published to JetBrains Marketplace)

## Key Architecture

### review.sh
- **Platform detection**: `detect_platform()` uses `gh auth status` / `glab auth status`
- **Two modes**: `gstack` (clone repo, full context) and `builtin` (diff-only, faster)
- **Clone cache**: `~/.claude-code-reviewer/repos/` — clone once, `git fetch` on subsequent reviews
- **Explicit refspec**: `git fetch origin "+refs/heads/branch:refs/remotes/origin/branch"` (plain fetch only goes to FETCH_HEAD)
- **Claude invocation**: `run_claude()` uses `claude -p --verbose --allowedTools "..." < prompt`
- **Direct URL mode**: `./review.sh <URL>` bypasses polling, reviews single PR/MR
- **GitLab inline comments**: Uses `jq -n | glab api --input -` for nested JSON (not `-f "position[key]=value"` which sends flat keys)

### VS Code Extension
- Wraps `review.sh` — no duplicated logic
- `spawn('bash', [reviewShPath, prUrl])` with streaming output to Output Channel
- PR detection via `gh pr view --json url` / `glab mr view --output json`
- Published: shubhesh07.claude-code-reviewer on VS Code Marketplace

### JetBrains Plugin
- Wraps `review.sh` — same approach as VS Code extension
- `GeneralCommandLine` + `OSProcessHandler` → streams to `ConsoleView`
- Tools menu: "Review Current PR with Claude" and "Review PR by URL with Claude"
- Targets IntelliJ 2024.1+ (compatible with GoLand, IntelliJ, WebStorm, PyCharm)
- Published: Claude Code Reviewer on JetBrains Marketplace
- Build: `JAVA_HOME=<jbr-17-path> ./gradlew buildPlugin` → ZIP in `build/distributions/`
- Install: Settings → Plugins → Marketplace → search "Claude Code Reviewer" (or Install from Disk with ZIP)

## Build Commands

### VS Code Extension
```bash
cd vscode-extension
npm install && npm run compile
npm run package  # produces .vsix
```

### JetBrains Plugin
```bash
cd jetbrains-plugin
# Needs Java 17 — use JetBrains JBR from Gradle cache:
JAVA_HOME=~/.gradle/caches/8.10/transforms/*/transformed/ideaIC-*/jbr/Contents/Home ./gradlew buildPlugin
# Output: build/distributions/claude-code-reviewer-0.1.0.zip
```

## Config (config.env)
- `PLATFORM=gitlab` (user's setup)
- `USERNAME=shubhesh07`
- `REVIEW_TOOL=gstack`
- `REVIEW_ROLE=reviewer`

## Known Issues
- **Inline comments on GitLab**: Comments may appear in Activity/Overview instead of inline on Changes tab. Root cause: position data (base_sha, head_sha, start_sha) or line numbers may not match the diff. The `jq + glab api --input` pattern sends correct nested JSON but the position data itself needs to be accurate.

## User Preferences
- No co-author line in commits
- Prefers separate branches for features
- Platform: GitLab (Truemeds)
