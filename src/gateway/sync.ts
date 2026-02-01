import type { Sandbox } from '@cloudflare/sandbox';
import type { MoltbotEnv } from '../types';

export interface SyncResult {
  success: boolean;
  lastSync?: string;
  error?: string;
  details?: string;
}

/**
 * With direct R2 mounting, sync is a no-op.
 * All container writes go directly to R2 via s3fs.
 * This function is kept for API compatibility.
 */
export async function syncToR2(_sandbox: Sandbox, _env: MoltbotEnv): Promise<SyncResult> {
  return {
    success: true,
    lastSync: new Date().toISOString(),
    details: 'Direct R2 mount - no sync needed',
  };
}
