#!/usr/bin/env bash
set -euo pipefail

# Prevent nested Claude Code sessions
unset CLAUDECODE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
STATE_FILE="$SCRIPT_DIR/reviewed-prs.txt"
LOG_FILE="$SCRIPT_DIR/review.log"
CHECKLIST_FILE="$SCRIPT_DIR/checklist.md"
GREPTILE_HISTORY="${HOME}/.gstack/greptile-history.md"

# ─── Logging ───────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

# ─── Load Config ───────────────────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  die "config.env not found. Run ./setup.sh first."
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

PLATFORM="${PLATFORM:-auto}"
USERNAME="${USERNAME:-}"
POLL_INTERVAL="${POLL_INTERVAL:-900}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
REVIEW_TOOL="${REVIEW_TOOL:-gstack}"
REVIEW_ROLE="${REVIEW_ROLE:-reviewer}"
MAX_FILES="${MAX_FILES:-100}"
MAX_PRS_PER_RUN="${MAX_PRS_PER_RUN:-10}"
LOG_MAX_LINES="${LOG_MAX_LINES:-5000}"
GREPTILE_TRIAGE="${GREPTILE_TRIAGE:-true}"

# Load checklist
CHECKLIST=""
if [[ -f "$CHECKLIST_FILE" ]]; then
  CHECKLIST="$(cat "$CHECKLIST_FILE")"
fi

# Ensure state file exists
touch "$STATE_FILE"

# ─── Platform Detection ───────────────────────────────────────────────────────

detect_platform() {
  if [[ "$PLATFORM" != "auto" ]]; then
    echo "$PLATFORM"
    return
  fi
  if command -v gh &>/dev/null && gh auth status &>/dev/null; then
    echo "github"
  elif command -v glab &>/dev/null && glab auth status &>/dev/null; then
    echo "gitlab"
  else
    die "Cannot auto-detect platform. Install and authenticate gh or glab, or set PLATFORM in config.env."
  fi
}

detect_username() {
  local platform="$1"
  if [[ -n "$USERNAME" ]]; then
    echo "$USERNAME"
    return
  fi
  case "$platform" in
    github) gh api user --jq '.login' 2>/dev/null || die "Cannot detect GitHub username. Set USERNAME in config.env." ;;
    gitlab) glab api user 2>/dev/null | jq -r '.username' || die "Cannot detect GitLab username. Set USERNAME in config.env." ;;
  esac
}

# ─── Greptile Integration (GitHub only) ───────────────────────────────────────

# Fetch Greptile bot comments from a GitHub PR
# Returns JSON lines of comments, or empty string if none/error
github_fetch_greptile_comments() {
  local repo="$1" pr_number="$2"
  local line_comments="" top_comments=""

  # Fetch line-level review comments (position != null filters stale comments from force-pushes)
  line_comments="$(gh api "repos/${repo}/pulls/${pr_number}/comments" \
    --jq '.[] | select(.user.login == "greptile-apps[bot]") | select(.position != null) | {id: .id, path: .path, line: .line, body: .body, html_url: .html_url, source: "line-level"}' 2>/dev/null)" || true

  # Fetch top-level PR comments
  top_comments="$(gh api "repos/${repo}/issues/${pr_number}/comments" \
    --jq '.[] | select(.user.login == "greptile-apps[bot]") | {id: .id, body: .body, html_url: .html_url, source: "top-level"}' 2>/dev/null)" || true

  # Combine both
  local all_comments=""
  [[ -n "$line_comments" ]] && all_comments="$line_comments"
  if [[ -n "$top_comments" ]]; then
    [[ -n "$all_comments" ]] && all_comments="${all_comments}"$'\n'"${top_comments}" || all_comments="$top_comments"
  fi

  echo "$all_comments"
}

# Load Greptile suppression history for a specific repo
load_greptile_suppressions() {
  local repo="$1"
  if [[ ! -f "$GREPTILE_HISTORY" ]]; then
    echo ""
    return
  fi
  # Extract false-positive entries for this repo
  grep "| ${repo} | fp |" "$GREPTILE_HISTORY" 2>/dev/null || echo ""
}

# Build the Greptile triage section for the prompt
build_greptile_prompt_section() {
  local repo="$1" pr_number="$2" greptile_comments="$3" suppressions="$4"

  if [[ -z "$greptile_comments" ]]; then
    return
  fi

  local comment_count
  comment_count="$(echo "$greptile_comments" | grep -c '{' 2>/dev/null || echo "0")"

  cat <<GREPTILE

## Greptile Bot Comments (${comment_count} comments found)

The Greptile code review bot has posted comments on this PR. Triage each one:

### Classification Rules
For each Greptile comment, classify it as one of:
1. **VALID & ACTIONABLE** — a real bug/issue that exists in current code. Include in your CRITICAL findings.
2. **VALID BUT ALREADY FIXED** — a real issue already addressed in the diff. Reply: "Good catch — already fixed in this PR."
   - Reply command: \`gh api repos/${repo}/pulls/${pr_number}/comments/{COMMENT_ID}/replies -f body="Good catch — already fixed in this PR."\`
   - Or for top-level: \`gh api repos/${repo}/issues/${pr_number}/comments -f body="Good catch — already fixed in this PR."\`
3. **FALSE POSITIVE** — misunderstands the code, or is stylistic. Reply explaining why.
   - Reply command: \`gh api repos/${repo}/pulls/${pr_number}/comments/{COMMENT_ID}/replies -f body="<explanation>"\`

### Greptile Comments to Triage
\`\`\`json
${greptile_comments}
\`\`\`

### Suppression History (known false positives — skip these silently)
\`\`\`
${suppressions:-No suppression history yet.}
\`\`\`

### After Triage
Include a Greptile summary line in your output header:
\`+ N Greptile comments (X valid, Y fixed, Z FP)\`

For each comment, output:
- Classification tag: [VALID], [FIXED], [FALSE POSITIVE]
- File:line (or [top-level])
- One-line summary
- Permalink URL

Save new false positive patterns by running:
\`\`\`
mkdir -p ~/.gstack
echo "$(date +%Y-%m-%d) | ${repo} | fp | <file-pattern> | <category>" >> ~/.gstack/greptile-history.md
\`\`\`

Categories: race-condition, null-check, error-handling, style, type-safety, security, performance, correctness, other
GREPTILE
}

# ─── GitHub Functions ──────────────────────────────────────────────────────────

github_list_prs() {
  local username="$1"
  local query

  case "$REVIEW_ROLE" in
    reviewer) query="is:pr+is:open+review-requested:${username}" ;;
    assignee) query="is:pr+is:open+assignee:${username}" ;;
    author)   query="is:pr+is:open+author:${username}" ;;
    *)        die "Invalid REVIEW_ROLE: $REVIEW_ROLE" ;;
  esac

  gh api "search/issues?q=${query}&per_page=${MAX_PRS_PER_RUN}" --jq '.items[] | {
    url: .html_url,
    number: .number,
    title: .title,
    repo: (.repository_url | sub("https://api.github.com/repos/"; ""))
  }' 2>/dev/null || echo ""
}

github_get_diff() {
  local repo="$1" pr_number="$2"
  gh api "repos/${repo}/pulls/${pr_number}" \
    -H "Accept: application/vnd.github.v3.diff" 2>/dev/null || echo ""
}

github_get_file_count() {
  local repo="$1" pr_number="$2"
  gh api "repos/${repo}/pulls/${pr_number}" --jq '.changed_files' 2>/dev/null || echo "0"
}

github_get_pr_info() {
  local repo="$1" pr_number="$2"
  gh api "repos/${repo}/pulls/${pr_number}" --jq '{
    base_sha: .base.sha,
    head_sha: .head.sha,
    base_ref: .base.ref,
    head_ref: .head.ref
  }' 2>/dev/null || echo ""
}

github_build_builtin_prompt() {
  local repo="$1" pr_number="$2" diff="$3" pr_info="$4"
  local base_sha head_sha greptile_section=""
  base_sha="$(echo "$pr_info" | jq -r '.base_sha')"
  head_sha="$(echo "$pr_info" | jq -r '.head_sha')"

  # Greptile triage (GitHub only)
  if [[ "$GREPTILE_TRIAGE" == "true" ]]; then
    local greptile_comments suppressions
    greptile_comments="$(github_fetch_greptile_comments "$repo" "$pr_number")"
    if [[ -n "$greptile_comments" ]]; then
      suppressions="$(load_greptile_suppressions "$repo")"
      greptile_section="$(build_greptile_prompt_section "$repo" "$pr_number" "$greptile_comments" "$suppressions")"
      log "  Found Greptile comments — including in review"
    fi
  fi

  cat <<PROMPT
You are a code reviewer. Review this PR diff and post your findings as INLINE comments on the exact lines where issues occur.

## Repository: ${repo}
## PR #${pr_number}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Only flag real problems.** Skip anything that's fine.
- **Be terse.** One line problem, one line fix.

## How to Read the Diff
The diff below shows changed files. Each hunk header looks like:
  \`@@ -old_start,old_count +new_start,new_count @@ context\`
Lines starting with \`+\` are additions (new code). The line number for inline comments is the position in the NEW file. Count from \`new_start\` in the hunk header, incrementing for every line that is NOT a deletion (lines starting with \`-\`).

## CRITICAL: Post Inline Comments on Specific Lines
For EVERY issue you find, you MUST post it as an inline comment on the exact line where the issue occurs. Do NOT combine multiple issues into one comment. Do NOT skip inline comments and only post a summary.

**For each issue, run this command** (replace the placeholders):
\`\`\`
gh api repos/${repo}/pulls/${pr_number}/comments \\
  -f body="**[CRITICAL]** or **[INFO]**: <one-line description of the issue>
Fix: <suggested fix>" \\
  -f commit_id="${head_sha}" \\
  -f path="<file_path_from_diff>" \\
  -f side="RIGHT" \\
  -F line=<line_number_in_new_file>
\`\`\`

Example: if the diff shows \`+++ b/internal/service/handler.go\` and the issue is on line 42 of the new file:
\`\`\`
gh api repos/${repo}/pulls/${pr_number}/comments \\
  -f body="**[CRITICAL]** SQL injection: user input interpolated into query.
Fix: Use parameterized query with \\\`db.Query(sql, args...)\\\`" \\
  -f commit_id="${head_sha}" \\
  -f path="internal/service/handler.go" \\
  -f side="RIGHT" \\
  -F line=42
\`\`\`

## After All Inline Comments
Post ONE summary comment with the overall verdict:
\`\`\`
gh api repos/${repo}/issues/${pr_number}/comments -f body="<summary>"
\`\`\`
The summary should:
- Start with **LGTM**, **Approve with comments**, or **Request changes**
- List the count: "N issues (X critical, Y informational)"
- Use **Request changes** only if CRITICAL issues were found
${greptile_section}

## Diff
\`\`\`diff
${diff}
\`\`\`
PROMPT
}

github_build_gstack_prompt() {
  local repo="$1" pr_number="$2" pr_info="$3"
  local head_sha base_ref greptile_section=""
  head_sha="$(echo "$pr_info" | jq -r '.head_sha')"
  base_ref="$(echo "$pr_info" | jq -r '.base_ref')"

  # Greptile triage (GitHub only)
  if [[ "$GREPTILE_TRIAGE" == "true" ]]; then
    local greptile_comments suppressions
    greptile_comments="$(github_fetch_greptile_comments "$repo" "$pr_number")"
    if [[ -n "$greptile_comments" ]]; then
      suppressions="$(load_greptile_suppressions "$repo")"
      greptile_section="$(build_greptile_prompt_section "$repo" "$pr_number" "$greptile_comments" "$suppressions")"
      log "  Found Greptile comments — including in review"
    fi
  fi

  cat <<PROMPT
You are a code reviewer performing a pre-landing review using the gstack two-pass methodology. Analyze this branch's diff for structural issues that tests don't catch.

## Repository: ${repo}
## PR #${pr_number}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Read-only by default.** Do not modify any files. Only post comments.
- **Be terse.** One line problem, one line fix. No preamble, no "looks good overall."
- **Only flag real problems.** Skip anything that's fine.
- **Respect suppressions.** Do NOT flag items listed in the "DO NOT flag" section.

## Instructions

### Step 1: Fetch latest base and get the diff
Run these commands to get a fresh diff against the base branch:
\`\`\`
git fetch origin ${base_ref} --quiet
git diff origin/${base_ref}
\`\`\`

### Step 2: Read source files for context
For any files with changes that look potentially problematic, read the full file (not just the diff hunks) to understand the surrounding code. This helps avoid false positives. Focus on:
- Functions that touch databases, authentication, or external services
- Error handling and recovery paths
- Concurrency patterns (goroutines, threads, async)

### Step 3: Two-pass review
Apply the checklist against the diff in two passes:
1. **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions & Concurrency, Injection & Trust Boundaries
2. **Pass 2 (INFORMATIONAL):** Conditional Side Effects, Magic Numbers, Dead Code, Error Handling, Test Gaps, Performance, API Contracts, LLM Prompt Issues, Crypto & Entropy, Time Window Safety, Type Coercion

### Step 4: Post INLINE Comments on Specific Lines
CRITICAL: For EVERY issue you find, you MUST post it as an inline comment on the exact line of code where the issue occurs. Do NOT combine multiple issues into one comment. Do NOT skip inline comments.

**For each issue, run this command** (replace placeholders):
\`\`\`
gh api repos/${repo}/pulls/${pr_number}/comments \\
  -f body="**[CRITICAL]** or **[INFO]**: <one-line problem>
Fix: <suggested fix>" \\
  -f commit_id="${head_sha}" \\
  -f path="<file_path_from_diff>" \\
  -f side="RIGHT" \\
  -F line=<line_number_in_new_file>
\`\`\`

The \`path\` is from the diff header (\`+++ b/path/to/file.go\` → use \`path/to/file.go\`).
The \`line\` is the line number in the new version of the file. Read it from the diff hunk header \`@@ -old,count +new_start,count @@\` and count forward for non-deletion lines.

### Step 5: Post Summary
After all inline comments, post ONE summary:
\`\`\`
gh api repos/${repo}/issues/${pr_number}/comments -f body="<summary>"
\`\`\`
Start with **LGTM**, **Approve with comments**, or **Request changes** (only for CRITICAL issues).
${greptile_section}
PROMPT
}

# ─── GitLab Functions ──────────────────────────────────────────────────────────

gitlab_list_mrs() {
  local username="$1"
  local endpoint

  case "$REVIEW_ROLE" in
    reviewer) endpoint="merge_requests?reviewer_username=${username}&state=opened&scope=all&per_page=${MAX_PRS_PER_RUN}" ;;
    assignee) endpoint="merge_requests?assignee_username=${username}&state=opened&scope=all&per_page=${MAX_PRS_PER_RUN}" ;;
    author)   endpoint="merge_requests?author_username=${username}&state=opened&scope=all&per_page=${MAX_PRS_PER_RUN}" ;;
    *)        die "Invalid REVIEW_ROLE: $REVIEW_ROLE" ;;
  esac

  glab api "$endpoint" 2>/dev/null | jq -c '.[] | {
    url: .web_url,
    iid: .iid,
    title: .title,
    project_id: .project_id,
    source_branch: .source_branch,
    target_branch: .target_branch
  }' 2>/dev/null || echo ""
}

gitlab_get_diff() {
  local project_id="$1" mr_iid="$2"
  local version_id
  version_id="$(glab api "projects/${project_id}/merge_requests/${mr_iid}/versions" 2>/dev/null \
    | jq -r '.[0].id')" || { echo ""; return; }

  [[ -z "$version_id" || "$version_id" == "null" ]] && { echo ""; return; }

  glab api "projects/${project_id}/merge_requests/${mr_iid}/versions/${version_id}" 2>/dev/null \
    | jq -r '.diffs[] | "--- a/\(.old_path)\n+++ b/\(.new_path)\n\(.diff)"' 2>/dev/null || echo ""
}

gitlab_get_file_count() {
  local project_id="$1" mr_iid="$2"
  glab api "projects/${project_id}/merge_requests/${mr_iid}/changes" 2>/dev/null \
    | jq '.changes | length' 2>/dev/null || echo "0"
}

gitlab_get_diff_refs() {
  local project_id="$1" mr_iid="$2"
  glab api "projects/${project_id}/merge_requests/${mr_iid}/versions" 2>/dev/null \
    | jq -c '.[0] | {base_commit_sha, head_commit_sha, start_commit_sha}' 2>/dev/null || echo ""
}

gitlab_get_clone_url() {
  local project_id="$1"
  glab api "projects/${project_id}" 2>/dev/null | jq -r '.http_url_to_repo' 2>/dev/null || echo ""
}

gitlab_build_builtin_prompt() {
  local project_id="$1" mr_iid="$2" diff="$3" diff_refs="$4"
  local base_sha head_sha start_sha
  base_sha="$(echo "$diff_refs" | jq -r '.base_commit_sha')"
  head_sha="$(echo "$diff_refs" | jq -r '.head_commit_sha')"
  start_sha="$(echo "$diff_refs" | jq -r '.start_commit_sha')"

  cat <<PROMPT
You are a code reviewer. Review this MR diff and post your findings as INLINE comments on the exact lines where issues occur.

## Project ID: ${project_id}
## MR !${mr_iid}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Only flag real problems.** Skip anything that's fine.
- **Be terse.** One line problem, one line fix.

## How to Read the Diff
The diff below shows changed files. Each hunk header looks like:
  \`@@ -old_start,old_count +new_start,new_count @@ context\`
Lines starting with \`+\` are additions (new code). The line number for inline comments is the position in the NEW file. Count from \`new_start\` in the hunk header, incrementing for every line that is NOT a deletion (lines starting with \`-\`).

## CRITICAL: Post Inline Comments on Specific Lines
For EVERY issue you find, you MUST post it as an inline comment on the exact line where the issue occurs. Do NOT combine multiple issues into one comment. Do NOT skip inline comments and only post a summary.

**For each issue, run this command** (replace the placeholders):
\`\`\`
glab api "projects/${project_id}/merge_requests/${mr_iid}/discussions" \\
  -f body="**[CRITICAL]** or **[INFO]**: <one-line description>
Fix: <suggested fix>" \\
  -f "position[position_type]=text" \\
  -f "position[base_sha]=${base_sha}" \\
  -f "position[head_sha]=${head_sha}" \\
  -f "position[start_sha]=${start_sha}" \\
  -f "position[new_path]=<file_path>" \\
  -F "position[new_line]=<line_number_in_new_file>"
\`\`\`

The \`new_path\` is from the diff header (\`+++ b/path/to/file.go\` → use \`path/to/file.go\`).
The \`new_line\` is the line number in the new version of the file. Read it from the diff hunk header \`@@ -old,count +new_start,count @@\` and count forward for non-deletion lines.

Example: if diff shows \`+++ b/internal/handler.go\` with hunk \`@@ -10,5 +10,8 @@\` and the issue is on the 3rd non-deletion line in the hunk, the line number is 12 (10+2).

## After All Inline Comments
Post ONE summary comment with the overall verdict:
\`\`\`
glab api "projects/${project_id}/merge_requests/${mr_iid}/notes" -f body="<summary>"
\`\`\`
The summary should:
- Start with **LGTM**, **Approve with comments**, or **Request changes**
- List the count: "N issues (X critical, Y informational)"
- Use **Request changes** only if CRITICAL issues were found

## Diff
\`\`\`diff
${diff}
\`\`\`
PROMPT
}

gitlab_build_gstack_prompt() {
  local project_id="$1" mr_iid="$2" diff_refs="$3" target_branch="$4"
  local base_sha head_sha start_sha
  base_sha="$(echo "$diff_refs" | jq -r '.base_commit_sha')"
  head_sha="$(echo "$diff_refs" | jq -r '.head_commit_sha')"
  start_sha="$(echo "$diff_refs" | jq -r '.start_commit_sha')"

  cat <<PROMPT
You are a code reviewer performing a pre-landing review using the gstack two-pass methodology. Analyze this branch's diff for structural issues that tests don't catch.

## Project ID: ${project_id}
## MR !${mr_iid}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Read-only by default.** Do not modify any files. Only post comments.
- **Be terse.** One line problem, one line fix. No preamble, no "looks good overall."
- **Only flag real problems.** Skip anything that's fine.
- **Respect suppressions.** Do NOT flag items listed in the "DO NOT flag" section.

## Instructions

### Step 1: Fetch latest target and get the diff
Run these commands to get a fresh diff against the target branch:
\`\`\`
git fetch origin ${target_branch} --quiet
git diff origin/${target_branch}
\`\`\`

### Step 2: Read source files for context
For any files with changes that look potentially problematic, read the full file (not just the diff hunks) to understand the surrounding code. This helps avoid false positives. Focus on:
- Functions that touch databases, authentication, or external services
- Error handling and recovery paths
- Concurrency patterns (goroutines, threads, async)

### Step 3: Two-pass review
Apply the checklist against the diff in two passes:
1. **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions & Concurrency, Injection & Trust Boundaries
2. **Pass 2 (INFORMATIONAL):** Conditional Side Effects, Magic Numbers, Dead Code, Error Handling, Test Gaps, Performance, API Contracts, LLM Prompt Issues, Crypto & Entropy, Time Window Safety, Type Coercion

### Step 4: Post INLINE Comments on Specific Lines
CRITICAL: For EVERY issue you find, you MUST post it as an inline comment on the exact line of code where the issue occurs. Do NOT combine multiple issues into one comment. Do NOT skip inline comments.

**For each issue, run this command** (replace placeholders):
\`\`\`
glab api "projects/${project_id}/merge_requests/${mr_iid}/discussions" \\
  -f body="**[CRITICAL]** or **[INFO]**: <one-line problem>
Fix: <suggested fix>" \\
  -f "position[position_type]=text" \\
  -f "position[base_sha]=${base_sha}" \\
  -f "position[head_sha]=${head_sha}" \\
  -f "position[start_sha]=${start_sha}" \\
  -f "position[new_path]=<file_path>" \\
  -F "position[new_line]=<line_number_in_new_file>"
\`\`\`

The \`new_path\` is from the diff header (\`+++ b/path/to/file.go\` → use \`path/to/file.go\`).
The \`new_line\` is the line number in the new version of the file. From the \`git diff\` output, read the hunk header \`@@ -old,count +new_start,count @@\` and count forward for non-deletion lines.

### Step 5: Post Summary
After all inline comments, post ONE summary:
\`\`\`
glab api "projects/${project_id}/merge_requests/${mr_iid}/notes" -f body="<summary>"
\`\`\`
Start with **LGTM**, **Approve with comments**, or **Request changes** (only for CRITICAL issues).
PROMPT
}

# ─── Clone Helpers (gstack mode) ──────────────────────────────────────────────

github_clone_pr() {
  local repo="$1" pr_number="$2" tmpdir="$3"

  log "  Cloning ${repo} (shallow)..."
  gh repo clone "$repo" "$tmpdir" -- --depth=1 --single-branch --quiet 2>/dev/null || return 1

  log "  Checking out PR #${pr_number}..."
  (cd "$tmpdir" && gh pr checkout "$pr_number" --force 2>/dev/null) || return 1

  return 0
}

gitlab_clone_mr() {
  local project_id="$1" mr_iid="$2" source_branch="$3" target_branch="$4" tmpdir="$5"

  local clone_url
  clone_url="$(gitlab_get_clone_url "$project_id")"
  if [[ -z "$clone_url" ]]; then
    log "  Cannot get clone URL for project ${project_id}"
    return 1
  fi

  log "  Cloning project ${project_id} (shallow)..."
  git clone --depth=1 --single-branch --branch "$source_branch" --quiet "$clone_url" "$tmpdir" 2>/dev/null || return 1

  # Fetch the target branch for diffing (minimal depth)
  (cd "$tmpdir" && git fetch origin "$target_branch" --depth=1 --quiet 2>/dev/null) || true

  return 0
}

cleanup_tmpdir() {
  local tmpdir="$1"
  if [[ -n "$tmpdir" && -d "$tmpdir" ]]; then
    rm -rf "$tmpdir"
  fi
}

# ─── Review Engine ─────────────────────────────────────────────────────────────

is_reviewed() {
  local url="$1"
  grep -qF "$url" "$STATE_FILE" 2>/dev/null
}

mark_reviewed() {
  local url="$1"
  echo "$url" >> "$STATE_FILE"
}

run_claude() {
  local prompt="$1"
  local workdir="${2:-}"
  local mode="${3:-builtin}"

  # Base tools: platform CLIs for posting comments
  local tools=("Bash(gh:*)" "Bash(glab:*)")

  if [[ "$mode" == "gstack" ]]; then
    # gstack mode: Claude needs git, file reading, and search for full context
    tools+=("Bash(git:*)" "Bash(cat:*)" "Bash(mkdir:*)" "Bash(echo:*)" "Read" "Grep" "Glob")
  fi

  local cmd=(claude -p --verbose)
  for tool in "${tools[@]}"; do
    cmd+=(--allowedTools "$tool")
  done

  if [[ -n "$CLAUDE_MODEL" ]]; then
    cmd+=(--model "$CLAUDE_MODEL")
  fi

  # Stream output to terminal in real-time (tee to both stdout and log)
  if [[ "$mode" == "gstack" && -n "$workdir" ]]; then
    (cd "$workdir" && echo "$prompt" | "${cmd[@]}")
  else
    echo "$prompt" | "${cmd[@]}"
  fi
}

review_github() {
  local username="$1"
  local count=0

  log "Fetching GitHub PRs for @${username} (role: ${REVIEW_ROLE})..."

  local prs_json
  prs_json="$(github_list_prs "$username")"

  if [[ -z "$prs_json" ]]; then
    log "No open PRs found."
    return
  fi

  while IFS= read -r pr_line; do
    [[ -z "$pr_line" ]] && continue

    local url repo pr_number title
    url="$(echo "$pr_line" | jq -r '.url')"
    repo="$(echo "$pr_line" | jq -r '.repo')"
    pr_number="$(echo "$pr_line" | jq -r '.number')"
    title="$(echo "$pr_line" | jq -r '.title')"

    if is_reviewed "$url"; then
      log "Skipping (already reviewed): ${url}"
      continue
    fi

    local file_count
    file_count="$(github_get_file_count "$repo" "$pr_number")"
    if [[ "$file_count" -gt "$MAX_FILES" ]]; then
      log "Skipping (${file_count} files > MAX_FILES=${MAX_FILES}): ${url}"
      mark_reviewed "$url"
      continue
    fi

    log "Reviewing PR #${pr_number}: ${title} (${file_count} files) [${REVIEW_TOOL} mode]"

    local pr_info
    pr_info="$(github_get_pr_info "$repo" "$pr_number")"
    if [[ -z "$pr_info" ]]; then
      log "Skipping (cannot get PR info): ${url}"
      continue
    fi

    local prompt tmpdir=""
    local review_ok=false

    if [[ "$REVIEW_TOOL" == "gstack" ]]; then
      # gstack mode: clone repo for full source context
      tmpdir="$(mktemp -d)"
      if github_clone_pr "$repo" "$pr_number" "$tmpdir"; then
        prompt="$(github_build_gstack_prompt "$repo" "$pr_number" "$pr_info")"
        if run_claude "$prompt" "$tmpdir" "gstack"; then
          review_ok=true
        fi
      else
        log "  Clone failed, falling back to builtin mode"
        local diff
        diff="$(github_get_diff "$repo" "$pr_number")"
        if [[ -n "$diff" ]]; then
          prompt="$(github_build_builtin_prompt "$repo" "$pr_number" "$diff" "$pr_info")"
          if run_claude "$prompt" "" "builtin"; then
            review_ok=true
          fi
        fi
      fi
      cleanup_tmpdir "$tmpdir"
    else
      # builtin mode: diff-only review
      local diff
      diff="$(github_get_diff "$repo" "$pr_number")"
      if [[ -z "$diff" ]]; then
        log "Skipping (empty diff): ${url}"
        mark_reviewed "$url"
        continue
      fi
      prompt="$(github_build_builtin_prompt "$repo" "$pr_number" "$diff" "$pr_info")"
      if run_claude "$prompt" "" "builtin"; then
        review_ok=true
      fi
    fi

    if [[ "$review_ok" == "true" ]]; then
      mark_reviewed "$url"
      log "Completed review: ${url}"
    else
      log "Claude review failed for: ${url}"
    fi

    count=$((count + 1))
    if [[ "$count" -ge "$MAX_PRS_PER_RUN" ]]; then
      log "Reached MAX_PRS_PER_RUN (${MAX_PRS_PER_RUN}), stopping."
      break
    fi
  done <<< "$prs_json"
}

review_gitlab() {
  local username="$1"
  local count=0

  log "Fetching GitLab MRs for @${username} (role: ${REVIEW_ROLE})..."

  local mrs_json
  mrs_json="$(gitlab_list_mrs "$username")"

  if [[ -z "$mrs_json" ]]; then
    log "No open MRs found."
    return
  fi

  while IFS= read -r mr_line; do
    [[ -z "$mr_line" ]] && continue

    local url project_id mr_iid title source_branch target_branch
    url="$(echo "$mr_line" | jq -r '.url')"
    project_id="$(echo "$mr_line" | jq -r '.project_id')"
    mr_iid="$(echo "$mr_line" | jq -r '.iid')"
    title="$(echo "$mr_line" | jq -r '.title')"
    source_branch="$(echo "$mr_line" | jq -r '.source_branch')"
    target_branch="$(echo "$mr_line" | jq -r '.target_branch')"

    if is_reviewed "$url"; then
      log "Skipping (already reviewed): ${url}"
      continue
    fi

    local file_count
    file_count="$(gitlab_get_file_count "$project_id" "$mr_iid")"
    if [[ "$file_count" -gt "$MAX_FILES" ]]; then
      log "Skipping (${file_count} files > MAX_FILES=${MAX_FILES}): ${url}"
      mark_reviewed "$url"
      continue
    fi

    log "Reviewing MR !${mr_iid}: ${title} (${file_count} files) [${REVIEW_TOOL} mode]"

    local diff_refs
    diff_refs="$(gitlab_get_diff_refs "$project_id" "$mr_iid")"
    if [[ -z "$diff_refs" ]]; then
      log "Skipping (cannot get diff refs): ${url}"
      continue
    fi

    local prompt tmpdir=""
    local review_ok=false

    if [[ "$REVIEW_TOOL" == "gstack" ]]; then
      # gstack mode: clone repo for full source context
      tmpdir="$(mktemp -d)"
      if gitlab_clone_mr "$project_id" "$mr_iid" "$source_branch" "$target_branch" "$tmpdir"; then
        prompt="$(gitlab_build_gstack_prompt "$project_id" "$mr_iid" "$diff_refs" "$target_branch")"
        if run_claude "$prompt" "$tmpdir" "gstack"; then
          review_ok=true
        fi
      else
        log "  Clone failed, falling back to builtin mode"
        local diff
        diff="$(gitlab_get_diff "$project_id" "$mr_iid")"
        if [[ -n "$diff" ]]; then
          prompt="$(gitlab_build_builtin_prompt "$project_id" "$mr_iid" "$diff" "$diff_refs")"
          if run_claude "$prompt" "" "builtin"; then
            review_ok=true
          fi
        fi
      fi
      cleanup_tmpdir "$tmpdir"
    else
      # builtin mode: diff-only review
      local diff
      diff="$(gitlab_get_diff "$project_id" "$mr_iid")"
      if [[ -z "$diff" ]]; then
        log "Skipping (empty diff): ${url}"
        mark_reviewed "$url"
        continue
      fi
      prompt="$(gitlab_build_builtin_prompt "$project_id" "$mr_iid" "$diff" "$diff_refs")"
      if run_claude "$prompt" "" "builtin"; then
        review_ok=true
      fi
    fi

    if [[ "$review_ok" == "true" ]]; then
      mark_reviewed "$url"
      log "Completed review: ${url}"
    else
      log "Claude review failed for: ${url}"
    fi

    count=$((count + 1))
    if [[ "$count" -ge "$MAX_PRS_PER_RUN" ]]; then
      log "Reached MAX_PRS_PER_RUN (${MAX_PRS_PER_RUN}), stopping."
      break
    fi
  done <<< "$mrs_json"
}

# ─── Direct URL Review ─────────────────────────────────────────────────────────

# Parse a GitHub PR URL: https://github.com/OWNER/REPO/pull/NUM
parse_github_url() {
  local url="$1"
  local repo pr_number
  # Extract owner/repo and PR number from URL
  repo="$(echo "$url" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/pull/([0-9]+).*|\1|')"
  pr_number="$(echo "$url" | sed -E 's|https?://github\.com/([^/]+/[^/]+)/pull/([0-9]+).*|\2|')"
  echo "${repo}|${pr_number}"
}

# Parse a GitLab MR URL: https://gitlab.com/GROUP/.../PROJECT/-/merge_requests/IID
parse_gitlab_url() {
  local url="$1"
  local mr_iid
  mr_iid="$(echo "$url" | sed -E 's|.*/merge_requests/([0-9]+).*|\1|')"
  echo "$mr_iid"
}

# Get GitLab project_id and MR details from URL
gitlab_mr_info_from_url() {
  local url="$1" mr_iid="$2"
  # Extract the project path from URL (everything between gitlab.com/ and /-/merge_requests)
  local project_path
  project_path="$(echo "$url" | sed -E 's|https?://[^/]+/(.+)/-/merge_requests/[0-9]+.*|\1|')"
  local encoded_path
  encoded_path="$(echo "$project_path" | sed 's|/|%2F|g')"

  glab api "projects/${encoded_path}" 2>/dev/null | jq -r '.id' 2>/dev/null || echo ""
}

review_single_github_pr() {
  local url="$1"
  local parsed repo pr_number
  parsed="$(parse_github_url "$url")"
  repo="${parsed%%|*}"
  pr_number="${parsed##*|}"

  if [[ -z "$repo" || -z "$pr_number" || "$repo" == "$url" ]]; then
    die "Cannot parse GitHub PR URL: ${url}"
  fi

  log "Reviewing GitHub PR: ${repo}#${pr_number}"

  local pr_info
  pr_info="$(github_get_pr_info "$repo" "$pr_number")"
  if [[ -z "$pr_info" ]]; then
    die "Cannot get PR info for ${url}"
  fi

  local prompt tmpdir=""
  local review_ok=false

  if [[ "$REVIEW_TOOL" == "gstack" ]]; then
    tmpdir="$(mktemp -d)"
    if github_clone_pr "$repo" "$pr_number" "$tmpdir"; then
      prompt="$(github_build_gstack_prompt "$repo" "$pr_number" "$pr_info")"
      if run_claude "$prompt" "$tmpdir" "gstack"; then
        review_ok=true
      fi
    else
      log "  Clone failed, falling back to builtin mode"
      local diff
      diff="$(github_get_diff "$repo" "$pr_number")"
      if [[ -n "$diff" ]]; then
        prompt="$(github_build_builtin_prompt "$repo" "$pr_number" "$diff" "$pr_info")"
        if run_claude "$prompt" "" "builtin"; then
          review_ok=true
        fi
      fi
    fi
    cleanup_tmpdir "$tmpdir"
  else
    local diff
    diff="$(github_get_diff "$repo" "$pr_number")"
    if [[ -z "$diff" ]]; then
      die "Empty diff for ${url}"
    fi
    prompt="$(github_build_builtin_prompt "$repo" "$pr_number" "$diff" "$pr_info")"
    if run_claude "$prompt" "" "builtin"; then
      review_ok=true
    fi
  fi

  if [[ "$review_ok" == "true" ]]; then
    mark_reviewed "$url"
    log "Completed review: ${url}"
  else
    log "Claude review failed for: ${url}"
  fi
}

review_single_gitlab_mr() {
  local url="$1"
  local mr_iid
  mr_iid="$(parse_gitlab_url "$url")"

  if [[ -z "$mr_iid" || "$mr_iid" == "$url" ]]; then
    die "Cannot parse GitLab MR URL: ${url}"
  fi

  local project_id
  project_id="$(gitlab_mr_info_from_url "$url" "$mr_iid")"
  if [[ -z "$project_id" || "$project_id" == "null" ]]; then
    die "Cannot get project ID for ${url}"
  fi

  # Get MR details for source/target branch
  local mr_details source_branch target_branch title
  mr_details="$(glab api "projects/${project_id}/merge_requests/${mr_iid}" 2>/dev/null)"
  source_branch="$(echo "$mr_details" | jq -r '.source_branch')"
  target_branch="$(echo "$mr_details" | jq -r '.target_branch')"
  title="$(echo "$mr_details" | jq -r '.title')"

  log "Reviewing GitLab MR !${mr_iid}: ${title}"

  local diff_refs
  diff_refs="$(gitlab_get_diff_refs "$project_id" "$mr_iid")"
  if [[ -z "$diff_refs" ]]; then
    die "Cannot get diff refs for ${url}"
  fi

  local prompt tmpdir=""
  local review_ok=false

  if [[ "$REVIEW_TOOL" == "gstack" ]]; then
    tmpdir="$(mktemp -d)"
    if gitlab_clone_mr "$project_id" "$mr_iid" "$source_branch" "$target_branch" "$tmpdir"; then
      prompt="$(gitlab_build_gstack_prompt "$project_id" "$mr_iid" "$diff_refs" "$target_branch")"
      if run_claude "$prompt" "$tmpdir" "gstack"; then
        review_ok=true
      fi
    else
      log "  Clone failed, falling back to builtin mode"
      local diff
      diff="$(gitlab_get_diff "$project_id" "$mr_iid")"
      if [[ -n "$diff" ]]; then
        prompt="$(gitlab_build_builtin_prompt "$project_id" "$mr_iid" "$diff" "$diff_refs")"
        if run_claude "$prompt" "" "builtin"; then
          review_ok=true
        fi
      fi
    fi
    cleanup_tmpdir "$tmpdir"
  else
    local diff
    diff="$(gitlab_get_diff "$project_id" "$mr_iid")"
    if [[ -z "$diff" ]]; then
      die "Empty diff for ${url}"
    fi
    prompt="$(gitlab_build_builtin_prompt "$project_id" "$mr_iid" "$diff" "$diff_refs")"
    if run_claude "$prompt" "" "builtin"; then
      review_ok=true
    fi
  fi

  if [[ "$review_ok" == "true" ]]; then
    mark_reviewed "$url"
    log "Completed review: ${url}"
  else
    log "Claude review failed for: ${url}"
  fi
}

# ─── Log Rotation ─────────────────────────────────────────────────────────────

trim_log() {
  if [[ -f "$LOG_FILE" ]]; then
    local lines
    lines="$(wc -l < "$LOG_FILE")"
    if [[ "$lines" -gt "$LOG_MAX_LINES" ]]; then
      local tmp
      tmp="$(mktemp)"
      tail -n "$LOG_MAX_LINES" "$LOG_FILE" > "$tmp"
      mv "$tmp" "$LOG_FILE"
      log "Trimmed log to ${LOG_MAX_LINES} lines."
    fi
  fi
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
  log "=== claude-code-reviewer starting ==="

  if ! command -v claude &>/dev/null; then
    die "claude CLI not found. Install from: https://docs.anthropic.com/en/docs/claude-code"
  fi

  if ! command -v jq &>/dev/null; then
    die "jq not found. Install: brew install jq (macOS) or apt install jq (Linux)"
  fi

  if [[ "$REVIEW_TOOL" == "gstack" ]] && ! command -v git &>/dev/null; then
    die "git not found. gstack mode requires git for cloning repos."
  fi

  # Direct URL mode: ./review.sh <PR/MR URL>
  if [[ $# -gt 0 && "$1" =~ ^https?:// ]]; then
    local url="$1"
    log "Direct review mode: ${url}"

    if [[ "$url" =~ github\.com.*pull/[0-9]+ ]]; then
      review_single_github_pr "$url"
    elif [[ "$url" =~ merge_requests/[0-9]+ ]]; then
      review_single_gitlab_mr "$url"
    else
      die "Unrecognized URL format. Expected GitHub PR or GitLab MR URL."
    fi

    trim_log
    log "=== claude-code-reviewer finished ==="
    return
  fi

  # Poll mode: review all open PRs/MRs
  local platform username
  platform="$(detect_platform)"
  username="$(detect_username "$platform")"

  log "Platform: ${platform} | User: ${username} | Role: ${REVIEW_ROLE} | Tool: ${REVIEW_TOOL} | Greptile: ${GREPTILE_TRIAGE}"

  case "$platform" in
    github) review_github "$username" ;;
    gitlab) review_gitlab "$username" ;;
    *) die "Unknown platform: ${platform}" ;;
  esac

  trim_log
  log "=== claude-code-reviewer finished ==="
}

main "$@"
