import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';

export function getReviewShPath(): string {
    const config = vscode.workspace.getConfiguration('claude-reviewer');
    const configured = config.get<string>('reviewShPath', '');
    if (configured && fs.existsSync(configured)) {
        return configured;
    }

    // Look in ~/claude-code-reviewer/review.sh (default install location)
    const homeDir = process.env.HOME || process.env.USERPROFILE || '';
    const homePath = path.join(homeDir, 'claude-code-reviewer', 'review.sh');
    if (fs.existsSync(homePath)) {
        return homePath;
    }

    throw new Error(
        'Cannot find review.sh. Install claude-code-reviewer first:\n' +
        'git clone https://github.com/shubhesh07/claude-code-reviewer.git ~/claude-code-reviewer && cd ~/claude-code-reviewer && ./setup.sh\n\n' +
        'Or set "claude-reviewer.reviewShPath" in VS Code settings.'
    );
}
