import * as vscode from 'vscode';
import * as path from 'path';
import * as fs from 'fs';
import { spawn, ChildProcess, execSync } from 'child_process';
import { getReviewShPath } from '../utils/config';

const REPO_URL = 'https://github.com/shubhesh07/claude-code-reviewer.git';
const INSTALL_DIR = path.join(process.env.HOME || process.env.USERPROFILE || '', 'claude-code-reviewer');

export interface ReviewResult {
    exitCode: number;
    killed: boolean;
}

function buildEnvPath(): string {
    return `${process.env.PATH}:/usr/local/bin:/opt/homebrew/bin`;
}

function spawnAndStream(
    command: string,
    args: string[],
    outputChannel: vscode.OutputChannel
): Promise<number> {
    return new Promise((resolve, reject) => {
        const child = spawn(command, args, {
            env: { ...process.env, PATH: buildEnvPath() },
        });

        child.stdout?.on('data', (data: Buffer) => {
            outputChannel.append(data.toString());
        });
        child.stderr?.on('data', (data: Buffer) => {
            outputChannel.append(data.toString());
        });
        child.on('close', (code) => resolve(code ?? 1));
        child.on('error', (err) => reject(err));
    });
}

async function installReviewCli(outputChannel: vscode.OutputChannel): Promise<string | null> {
    const choice = await vscode.window.showInformationMessage(
        'Claude Code Reviewer CLI is not installed. Install it automatically to ~/claude-code-reviewer?',
        'Install & Review',
        'Cancel'
    );

    if (choice !== 'Install & Review') { return null; }

    outputChannel.appendLine('');
    outputChannel.appendLine('='.repeat(60));
    outputChannel.appendLine('Installing Claude Code Reviewer CLI...');
    outputChannel.appendLine('='.repeat(60));
    outputChannel.appendLine('');
    outputChannel.show(true);

    const reviewShPath = path.join(INSTALL_DIR, 'review.sh');

    // Clone or pull
    if (fs.existsSync(INSTALL_DIR) && fs.existsSync(reviewShPath)) {
        outputChannel.appendLine('Repository already exists, pulling latest...');
        const pullCode = await spawnAndStream('git', ['-C', INSTALL_DIR, 'pull'], outputChannel);
        if (pullCode !== 0) {
            outputChannel.appendLine('Warning: git pull failed, continuing with existing version.');
        }
    } else {
        outputChannel.appendLine(`Cloning ${REPO_URL}...`);
        const cloneCode = await spawnAndStream('git', ['clone', REPO_URL, INSTALL_DIR], outputChannel);
        if (cloneCode !== 0) {
            outputChannel.appendLine('ERROR: git clone failed. Check your network connection.');
            return null;
        }
        outputChannel.appendLine('Cloned successfully.');
    }

    // Run setup.sh --auto
    const setupSh = path.join(INSTALL_DIR, 'setup.sh');
    if (fs.existsSync(setupSh)) {
        outputChannel.appendLine('');
        outputChannel.appendLine('Running setup.sh --auto...');
        const setupCode = await spawnAndStream('bash', [setupSh, '--auto'], outputChannel);
        if (setupCode !== 0) {
            outputChannel.appendLine('Setup finished with warnings. You may need to configure config.env manually.');
        } else {
            outputChannel.appendLine('Setup complete!');
        }
    }

    outputChannel.appendLine('');

    // Verify installation
    const found = getReviewShPath();
    if (found) {
        outputChannel.appendLine(`Found review.sh at: ${found}`);
        outputChannel.appendLine('');
        return found;
    }

    outputChannel.appendLine('ERROR: review.sh still not found after install. Check ~/claude-code-reviewer/ manually.');
    return null;
}

export async function runReview(
    prUrl: string,
    outputChannel: vscode.OutputChannel,
    cancellationToken: vscode.CancellationToken
): Promise<ReviewResult> {
    let reviewShPath = getReviewShPath();

    if (!reviewShPath) {
        reviewShPath = await installReviewCli(outputChannel);
        if (!reviewShPath) {
            throw new Error('review.sh not found. Install cancelled or failed.');
        }
    }

    return new Promise((resolve, reject) => {
        const timestamp = new Date().toLocaleString();
        outputChannel.appendLine('');
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine(`Claude Review Started: ${timestamp}`);
        outputChannel.appendLine(`PR/MR: ${prUrl}`);
        outputChannel.appendLine('='.repeat(60));
        outputChannel.appendLine('');
        outputChannel.show(true);

        const child: ChildProcess = spawn('bash', [reviewShPath!, prUrl], {
            env: {
                ...process.env,
                PATH: buildEnvPath(),
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
