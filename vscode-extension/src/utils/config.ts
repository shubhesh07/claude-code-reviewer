import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

const SKIP_DIRS = new Set([
    'Library', '.gradle', '.cache', 'node_modules', '.git',
    '.m2', '.npm', '.local', 'go', '.Trash', 'Applications',
]);

export function getReviewShPath(): string | null {
    // Tier 1: VS Code setting
    const config = vscode.workspace.getConfiguration('claude-reviewer');
    const configured = config.get<string>('reviewShPath', '');
    if (configured && fs.existsSync(configured)) {
        return configured;
    }

    // Tier 2: Environment variable
    const envPath = process.env.CLAUDE_REVIEWER_PATH;
    if (envPath) {
        const asDir = path.join(envPath, 'review.sh');
        if (fs.existsSync(asDir)) { return asDir; }
        if (fs.existsSync(envPath) && path.basename(envPath) === 'review.sh') { return envPath; }
    }

    // Tier 3: Standard directories
    const homeDir = process.env.HOME || process.env.USERPROFILE || '';
    const candidates = [
        path.join(homeDir, 'claude-code-reviewer', 'review.sh'),
        path.join(homeDir, '.claude-code-reviewer', 'review.sh'),
        '/usr/local/share/claude-code-reviewer/review.sh',
        '/opt/claude-code-reviewer/review.sh',
    ];
    for (const candidate of candidates) {
        if (fs.existsSync(candidate)) { return candidate; }
    }

    // Tier 4: Recursive home directory search
    if (homeDir) {
        const found = findReviewShRecursive(homeDir, 3);
        if (found) { return found; }
    }

    return null;
}

function findReviewShRecursive(dir: string, maxDepth: number, currentDepth: number = 0): string | null {
    if (currentDepth > maxDepth) { return null; }

    const reviewSh = path.join(dir, 'claude-code-reviewer', 'review.sh');
    if (fs.existsSync(reviewSh)) { return reviewSh; }

    if (currentDepth < maxDepth) {
        try {
            const entries = fs.readdirSync(dir, { withFileTypes: true });
            for (const entry of entries) {
                if (!entry.isDirectory() || entry.name.startsWith('.') && entry.name !== '.claude-code-reviewer' || SKIP_DIRS.has(entry.name)) {
                    continue;
                }
                const result = findReviewShRecursive(path.join(dir, entry.name), maxDepth, currentDepth + 1);
                if (result) { return result; }
            }
        } catch {
            // Permission denied or other fs errors — skip
        }
    }

    return null;
}
