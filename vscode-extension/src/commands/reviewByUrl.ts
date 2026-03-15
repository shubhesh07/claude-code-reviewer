import * as vscode from 'vscode';
import { runReview } from '../services/reviewRunner';

const URL_PATTERN = /^https?:\/\/.+(pull\/\d+|merge_requests\/\d+)/;

export async function reviewByUrl(outputChannel: vscode.OutputChannel): Promise<void> {
    const url = await vscode.window.showInputBox({
        prompt: 'Enter the PR/MR URL to review',
        placeHolder: 'https://github.com/owner/repo/pull/123',
        validateInput: (value) => {
            if (!value) { return 'URL is required'; }
            if (!URL_PATTERN.test(value)) {
                return 'Enter a valid GitHub PR URL (*/pull/N) or GitLab MR URL (*/merge_requests/N)';
            }
            return null;
        },
    });

    if (!url) { return; }

    vscode.window.showInformationMessage(`Starting review of ${url}...`);

    await vscode.window.withProgress(
        {
            location: vscode.ProgressLocation.Notification,
            title: `Reviewing: ${url}`,
            cancellable: true,
        },
        async (_progress, token) => {
            try {
                const result = await runReview(url, outputChannel, token);
                if (result.killed) {
                    vscode.window.showWarningMessage('Review cancelled.');
                } else if (result.exitCode === 0) {
                    const action = await vscode.window.showInformationMessage(
                        'Claude review complete! Comments posted to PR/MR.',
                        'Show Output'
                    );
                    if (action === 'Show Output') {
                        outputChannel.show();
                    }
                } else {
                    const action = await vscode.window.showWarningMessage(
                        `Review finished with errors (exit code ${result.exitCode}).`,
                        'Show Output'
                    );
                    if (action === 'Show Output') {
                        outputChannel.show();
                    }
                }
            } catch (err: unknown) {
                const message = err instanceof Error ? err.message : String(err);
                vscode.window.showErrorMessage(`Review failed: ${message}`);
            }
        }
    );
}
