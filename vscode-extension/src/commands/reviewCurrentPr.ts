import * as vscode from 'vscode';
import { detectCurrentPr } from '../services/prDetector';
import { runReview, runFix } from '../services/reviewRunner';

async function handleFixPrompt(prUrl: string, outputChannel: vscode.OutputChannel): Promise<void> {
    const action = await vscode.window.showInformationMessage(
        'Claude review complete! Comments posted to PR/MR.',
        'Fix Issues',
        'Show Output'
    );

    if (action === 'Fix Issues') {
        await vscode.window.withProgress(
            {
                location: vscode.ProgressLocation.Notification,
                title: `Fixing issues: ${prUrl}`,
                cancellable: true,
            },
            async (_progress, token) => {
                try {
                    const fixResult = await runFix(prUrl, outputChannel, token);
                    if (fixResult.killed) {
                        vscode.window.showWarningMessage('Fix cancelled.');
                    } else if (fixResult.exitCode === 0) {
                        vscode.window.showInformationMessage('Claude fixed the issues! Review the changes with `git diff`.');
                    } else {
                        vscode.window.showWarningMessage(`Fix finished with errors (exit code ${fixResult.exitCode}).`);
                    }
                } catch (err: unknown) {
                    const message = err instanceof Error ? err.message : String(err);
                    vscode.window.showErrorMessage(`Fix failed: ${message}`);
                }
            }
        );
    } else if (action === 'Show Output') {
        outputChannel.show();
    }
}

export async function reviewCurrentPr(outputChannel: vscode.OutputChannel): Promise<void> {
    const workspaceFolders = vscode.workspace.workspaceFolders;
    if (!workspaceFolders || workspaceFolders.length === 0) {
        vscode.window.showErrorMessage('No workspace folder open. Open a Git repository first.');
        return;
    }

    let workspaceFolder: string;
    if (workspaceFolders.length === 1) {
        workspaceFolder = workspaceFolders[0].uri.fsPath;
    } else {
        const picked = await vscode.window.showWorkspaceFolderPick({
            placeHolder: 'Select the repository to review',
        });
        if (!picked) { return; }
        workspaceFolder = picked.uri.fsPath;
    }

    const config = vscode.workspace.getConfiguration('claude-reviewer');
    const platform = config.get<string>('platform', 'auto');

    let prUrl: string;
    try {
        prUrl = await vscode.window.withProgress(
            {
                location: vscode.ProgressLocation.Notification,
                title: 'Detecting PR/MR for current branch...',
                cancellable: false,
            },
            async () => {
                const info = await detectCurrentPr(workspaceFolder, platform);
                return info.url;
            }
        );
    } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err);
        vscode.window.showErrorMessage(`Could not detect PR/MR: ${message}`);
        return;
    }

    vscode.window.showInformationMessage(`Found: ${prUrl}. Starting review...`);

    await vscode.window.withProgress(
        {
            location: vscode.ProgressLocation.Notification,
            title: `Reviewing: ${prUrl}`,
            cancellable: true,
        },
        async (_progress, token) => {
            try {
                const result = await runReview(prUrl, outputChannel, token);
                if (result.killed) {
                    vscode.window.showWarningMessage('Review cancelled.');
                } else if (result.exitCode === 0) {
                    await handleFixPrompt(prUrl, outputChannel);
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
