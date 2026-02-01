import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';
import { R2_MOUNT_PATH } from '../config';
import { mountR2Storage } from './r2';
import { waitForProcess } from './utils';

export interface SyncResult {
  success: boolean;
  lastSync?: string;
  error?: string;
  details?: string;
}

/**
 * Sync moltbot config from container to R2 for persistence.
 *
 * Uses a two-tier approach:
 * 1. Primary: Single-command tar backup via R2 binding (most reliable)
 * 2. Fallback: s3fs mount + rsync (used by cron when container is stable)
 *
 * The R2 binding approach only needs ONE sandbox.startProcess call,
 * which is critical because after deploys the DO may reset between calls.
 */
export async function syncToR2(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  // Check if R2 is configured
  if (!env.R2_ACCESS_KEY_ID || !env.R2_SECRET_ACCESS_KEY || !env.CF_ACCOUNT_ID) {
    return { success: false, error: 'R2 storage is not configured' };
  }

  // Try the R2 binding approach first (single process call, most resilient)
  const bindingResult = await syncViaBinding(sandbox, env);
  if (bindingResult.success) {
    return bindingResult;
  }

  // Don't fall back for definitive errors (source problem, not transport)
  if (bindingResult.error?.includes('source missing') || bindingResult.error?.includes('Sync aborted')) {
    return bindingResult;
  }

  console.log('[sync] Binding approach failed, trying s3fs mount approach:', bindingResult.error);

  // Fallback to s3fs mount + rsync approach
  return syncViaMountRsync(sandbox, env);
}

/**
 * Primary sync: tar files in one command, upload via R2 binding.
 * Only needs ONE startProcess call — survives DO instability.
 */
async function syncViaBinding(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  try {
    // Single command: check config exists, tar critical dirs, base64 encode, output timestamp
    // All in one process to avoid DO disconnect between calls
    const cmd = [
      'test -f /root/.clawdbot/clawdbot.json || { echo "MISSING_CONFIG"; exit 1; }',
      // Create tar of config + full workspace (exclude heavy/transient dirs)
      // Archives: .clawdbot/ (config) + clawd/ (workspace including skills/, memory/, etc.)
      'tar czf /tmp/moltbot-backup.tar.gz',
      '  --exclude=node_modules --exclude=.git',
      '  -C /root .clawdbot clawd',
      '  2>/dev/null',
      '|| tar czf /tmp/moltbot-backup.tar.gz -C /root .clawdbot 2>/dev/null',
      // Base64 encode for safe transport through process logs
      '&& base64 -w0 /tmp/moltbot-backup.tar.gz',
      '&& echo ""', // newline separator
      '&& echo "TAR_OK"',
    ].join(' ');

    const proc = await sandbox.startProcess(cmd);
    await waitForProcess(proc, 30000);
    const logs = await proc.getLogs();
    const stdout = logs.stdout || '';

    if (stdout.includes('MISSING_CONFIG')) {
      return {
        success: false,
        error: 'Sync aborted: source missing clawdbot.json',
        details: 'The local config directory is missing critical files.',
      };
    }

    if (!stdout.includes('TAR_OK')) {
      return {
        success: false,
        error: 'Tar command failed',
        details: logs.stderr || 'No TAR_OK marker in output',
      };
    }

    // Extract base64 data (everything before TAR_OK line)
    const lines = stdout.split('\n');
    const tarOkIndex = lines.findIndex(l => l === 'TAR_OK');
    if (tarOkIndex < 1) {
      return { success: false, error: 'Could not parse tar output' };
    }

    const base64Data = lines.slice(0, tarOkIndex).join('');
    if (!base64Data || base64Data.length < 100) {
      return { success: false, error: 'Tar output too small', details: `${base64Data.length} bytes` };
    }

    // Decode base64 and upload to R2 via binding
    const binaryData = Uint8Array.from(atob(base64Data), c => c.charCodeAt(0));
    const timestamp = new Date().toISOString();

    await env.MOLTBOT_BUCKET.put('backup.tar.gz', binaryData, {
      customMetadata: { timestamp, method: 'binding' },
    });
    await env.MOLTBOT_BUCKET.put('.last-sync', timestamp);

    return { success: true, lastSync: timestamp };
  } catch (err) {
    return {
      success: false,
      error: 'Binding sync error',
      details: err instanceof Error ? err.message : 'Unknown error',
    };
  }
}

/**
 * Fallback sync: s3fs mount + rsync (the original approach).
 * Needs multiple startProcess calls — only works when container is stable.
 */
async function syncViaMountRsync(sandbox: Sandbox, env: MoltbotEnv): Promise<SyncResult> {
  // Mount R2 if not already mounted
  const mounted = await mountR2Storage(sandbox, env);
  if (!mounted) {
    return { success: false, error: 'Failed to mount R2 storage' };
  }

  // Sanity check + rsync + timestamp in one chained command to minimize process calls
  const syncCmd = [
    `test -f /root/.clawdbot/clawdbot.json || { echo "MISSING_CONFIG"; exit 1; }`,
    `rsync -r --no-times --delete --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' /root/.clawdbot/ ${R2_MOUNT_PATH}/clawdbot/`,
    `rsync -r --no-times --delete /root/clawd/skills/ ${R2_MOUNT_PATH}/skills/`,
    `rsync -r --no-times --exclude='node_modules' --exclude='.git' --exclude='skills' /root/clawd/ ${R2_MOUNT_PATH}/workspace/`,
    `date -Iseconds > ${R2_MOUNT_PATH}/.last-sync`,
    `cat ${R2_MOUNT_PATH}/.last-sync`,
  ].join(' && ');

  try {
    const proc = await sandbox.startProcess(syncCmd);
    await waitForProcess(proc, 30000);
    const logs = await proc.getLogs();
    const stdout = logs.stdout || '';

    if (stdout.includes('MISSING_CONFIG')) {
      return {
        success: false,
        error: 'Sync aborted: source missing clawdbot.json',
        details: 'The local config directory is missing critical files.',
      };
    }

    const lastSync = stdout.trim().split('\n').pop()?.trim();
    if (lastSync && lastSync.match(/^\d{4}-\d{2}-\d{2}/)) {
      return { success: true, lastSync };
    } else {
      return {
        success: false,
        error: 'Sync failed',
        details: logs.stderr || logs.stdout || 'No timestamp produced',
      };
    }
  } catch (err) {
    return {
      success: false,
      error: 'Sync error',
      details: err instanceof Error ? err.message : 'Unknown error',
    };
  }
}
