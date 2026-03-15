import * as vscode from 'vscode';
import { spawn, ChildProcess } from 'child_process';
import { getReviewShPath } from '../utils/config';

export interface ReviewResult {
    exitCode: number;
    killed: boolean;
}

export async function runReview(
    prUrl: string,
    outputChannel: vscode.OutputChannel,
    cancellationToken: vscode.CancellationToken
): Promise<ReviewResult> {
    const reviewShPath = getReviewShPath();

    return new Promise((resolve, reject) => {
        const timestamp = new Date().toLocaleString();
        outputChannel.appendLine('');
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine(`Claude Review Started: ${timestamp}`);
        outputChannel.appendLine(`PR/MR: ${prUrl}`);
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine('');
        outputChannel.show(true);

        const child: ChildProcess = spawn('bash', [reviewShPath, prUrl], {
            env: {
                ...process.env,
                PATH: `${process.env.PATH}:/usr/local/bin:/opt/homebrew/bin`,
            },
        });

        child.stdout?.on('data', (data: Buffer) => {
            outputChannel.append(data.toString());
        });

        child.stderr?.on('data', (data: Buffer) => {
            outputChannel.append(data.toString());
        });

        child.on('close', (code) => {
            outputChannel.appendLine('');
            outputChannel.appendLine(`Review finished with exit code: ${code ?? 'unknown'}`);
            outputChannel.appendLine('='.repeat(60));
            resolve({ exitCode: code ?? 1, killed: false });
        });

        child.on('error', (err) => {
            outputChannel.appendLine(`Error: ${err.message}`);
            reject(err);
        });

        cancellationToken.onCancellationRequested(() => {
            child.kill('SIGTERM');
            outputChannel.appendLine('\nReview cancelled by user.');
            resolve({ exitCode: 1, killed: true });
        });
    });
}
