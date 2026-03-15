import * as vscode from 'vscode';
import { reviewCurrentPr } from './commands/reviewCurrentPr';
import { reviewByUrl } from './commands/reviewByUrl';

let outputChannel: vscode.OutputChannel;

export function activate(context: vscode.ExtensionContext) {
    outputChannel = vscode.window.createOutputChannel('Claude Reviewer');

    context.subscriptions.push(
        vscode.commands.registerCommand('claude-reviewer.reviewCurrentPr', () =>
            reviewCurrentPr(outputChannel)
        ),
        vscode.commands.registerCommand('claude-reviewer.reviewByUrl', () =>
            reviewByUrl(outputChannel)
        )
    );

    const statusBarItem = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Left,
        100
    );
    statusBarItem.text = '$(eye) Claude Reviewer';
    statusBarItem.tooltip = 'Review current PR/MR with Claude';
    statusBarItem.command = 'claude-reviewer.reviewCurrentPr';
    statusBarItem.show();
    context.subscriptions.push(statusBarItem);
}

export function deactivate() {
    outputChannel?.dispose();
}
