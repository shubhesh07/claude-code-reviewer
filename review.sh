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
You are a code reviewer performing a pre-landing review. Analyze the diff for structural issues that tests don't catch.

## Repository: ${repo}
## PR #${pr_number}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Read-only.** Do not modify any files. Only post comments.
- **Be terse.** One line problem, one line fix. No preamble, no "looks good overall."
- **Only flag real problems.** Skip anything that's fine.

## Instructions
1. Review the diff below against the checklist in two passes:
   - **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions & Concurrency, Injection & Trust Boundaries
   - **Pass 2 (INFORMATIONAL):** All remaining categories
2. For each issue found, post an inline comment on the specific line:
   \`\`\`
   gh api repos/${repo}/pulls/${pr_number}/comments -f body="<your comment>" -f commit_id="${head_sha}" -f path="<file_path>" -f side="RIGHT" -F line=<line_number>
   \`\`\`
3. After all inline comments, post a summary comment using the output format from the checklist:
   \`\`\`
   gh api repos/${repo}/issues/${pr_number}/comments -f body="<summary>"
   \`\`\`
4. The summary should start with one of: **LGTM**, **Approve with comments**, or **Request changes** (use Request changes only for CRITICAL issues).
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

### Step 4: Post findings
1. For each issue found, post an inline comment on the specific line:
   \`\`\`
   gh api repos/${repo}/pulls/${pr_number}/comments -f body="<your comment>" -f commit_id="${head_sha}" -f path="<file_path>" -f side="RIGHT" -F line=<line_number>
   \`\`\`
2. After all inline comments, post a summary comment using the output format from the checklist:
   \`\`\`
   gh api repos/${repo}/issues/${pr_number}/comments -f body="<summary>"
   \`\`\`
3. The summary should start with one of: **LGTM**, **Approve with comments**, or **Request changes** (use Request changes only for CRITICAL issues).
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
You are a code reviewer performing a pre-landing review. Analyze the diff for structural issues that tests don't catch.

## Project ID: ${project_id}
## MR !${mr_iid}

## Review Checklist
${CHECKLIST}

## Important Rules
- **Read the FULL diff before commenting.** Do not flag issues already addressed in the diff.
- **Read-only.** Do not modify any files. Only post comments.
- **Be terse.** One line problem, one line fix. No preamble, no "looks good overall."
- **Only flag real problems.** Skip anything that's fine.

## Instructions
1. Review the diff below against the checklist in two passes:
   - **Pass 1 (CRITICAL):** SQL & Data Safety, Race Conditions & Concurrency, Injection & Trust Boundaries
   - **Pass 2 (INFORMATIONAL):** All remaining categories
2. For each issue found, post an inline comment:
   \`\`\`
   glab api "projects/${project_id}/merge_requests/${mr_iid}/discussions" -f body="<your comment>" -f "position[position_type]=text" -f "position[base_sha]=${base_sha}" -f "position[head_sha]=${head_sha}" -f "position[start_sha]=${start_sha}" -f "position[new_path]=<file_path>" -f "position[new_line]=<line_number>"
   \`\`\`
3. After all inline comments, post a summary comment using the output format from the checklist:
   \`\`\`
   glab api "projects/${project_id}/merge_requests/${mr_iid}/notes" -f body="<summary>"
   \`\`\`
4. The summary should start with one of: **LGTM**, **Approve with comments**, or **Request changes** (use Request changes only for CRITICAL issues).

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

### Step 4: Post findings
1. For each issue found, post an inline comment:
   \`\`\`
   glab api "projects/${project_id}/merge_requests/${mr_iid}/discussions" -f body="<your comment>" -f "position[position_type]=text" -f "position[base_sha]=${base_sha}" -f "position[head_sha]=${head_sha}" -f "position[start_sha]=${start_sha}" -f "position[new_path]=<file_path>" -f "position[new_line]=<line_number>"
   \`\`\`
2. After all inline comments, post a summary comment using the output format from the checklist:
   \`\`\`
   glab api "projects/${project_id}/merge_requests/${mr_iid}/notes" -f body="<summary>"
   \`\`\`
3. The summary should start with one of: **LGTM**, **Approve with comments**, or **Request changes** (use Request changes only for CRITICAL issues).
PROMPT
}

# ─── Clone Helpers (gstack mode) ──────────────────────────────────────────────

github_clone_pr() {
  local repo="$1" pr_number="$2" tmpdir="$3"

  log "  Cloning ${repo} (shallow)..."
  gh repo clone "$repo" "$tmpdir" -- --depth=50 --quiet 2>/dev/null || return 1

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
  git clone --depth=50 --branch "$source_branch" --quiet "$clone_url" "$tmpdir" 2>/dev/null || return 1

  # Fetch the target branch for diffing
  (cd "$tmpdir" && git fetch origin "$target_branch" --depth=50 --quiet 2>/dev/null) || true

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

  if [[ "$mode" == "gstack" && -n "$workdir" ]]; then
    # Run Claude in the cloned repo directory for full source context
    (cd "$workdir" && echo "$prompt" | "${cmd[@]}" 2>&1)
  else
    echo "$prompt" | "${cmd[@]}" 2>&1
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
