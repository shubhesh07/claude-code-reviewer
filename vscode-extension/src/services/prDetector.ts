import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

export interface PrInfo {
    url: string;
    platform: 'github' | 'gitlab';
}

export async function detectCurrentPr(workspaceFolder: string, preferredPlatform: string): Promise<PrInfo> {
    if (preferredPlatform !== 'gitlab') {
        try {
            const { stdout } = await execFileAsync('gh', ['pr', 'view', '--json', 'url', '-q', '.url'], {
                cwd: workspaceFolder,
                timeout: 10000,
            });
            const url = stdout.trim();
            if (url && url.startsWith('http')) {
                return { url, platform: 'github' };
            }
        } catch {
            // gh not available or no PR for current branch
        }
    }

    if (preferredPlatform !== 'github') {
        try {
            const { stdout } = await execFileAsync('glab', ['mr', 'view', '--output', 'json'], {
                cwd: workspaceFolder,
                timeout: 10000,
            });
            const mrData = JSON.parse(stdout);
            if (mrData.web_url) {
                return { url: mrData.web_url, platform: 'gitlab' };
            }
        } catch {
            // glab not available or no MR for current branch
        }
    }

    throw new Error(
        'No PR/MR found for the current branch. ' +
        'Push your branch and create a PR/MR first, ' +
        'and ensure gh or glab CLI is authenticated.'
    );
}
