import { describe, it, expect, vi, beforeEach } from 'vitest';
import { syncToR2 } from './sync';
import {
  createMockEnv,
  createMockEnvWithR2,
  createMockProcess,
  createMockSandbox,
  suppressConsole
} from '../test-utils';

// Helper to create a valid base64 tar output (simulates tar | base64)
function createMockTarOutput(): string {
  // Create a valid base64 string (>100 chars, length must be multiple of 4)
  const fakeData = 'H4sIAAAAAAAA' + 'AAAA'.repeat(50); // 12 + 200 = 212 chars (212 % 4 = 0)
  return fakeData + '\nTAR_OK\n';
}

describe('syncToR2', () => {
  beforeEach(() => {
    suppressConsole();
  });

  describe('configuration checks', () => {
    it('returns error when R2 is not configured', async () => {
      const { sandbox } = createMockSandbox();
      const env = createMockEnv();

      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('R2 storage is not configured');
    });
  });

  describe('binding sync (primary)', () => {
    it('returns success when tar + R2 binding sync completes', async () => {
      const { sandbox, startProcessMock } = createMockSandbox();
      const mockPut = vi.fn().mockResolvedValue(undefined);

      // First call: binding approach - tar + base64 output
      startProcessMock.mockResolvedValueOnce(createMockProcess(createMockTarOutput()));

      const env = createMockEnvWithR2({
        MOLTBOT_BUCKET: { put: mockPut, get: vi.fn() } as any,
      });

      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(true);
      expect(result.lastSync).toMatch(/^\d{4}-\d{2}-\d{2}/);
      // Should have written backup.tar.gz and .last-sync to R2
      expect(mockPut).toHaveBeenCalledTimes(2);
      expect(mockPut.mock.calls[0][0]).toBe('backup.tar.gz');
      expect(mockPut.mock.calls[1][0]).toBe('.last-sync');
    });

    it('returns error when source is missing clawdbot.json', async () => {
      const { sandbox, startProcessMock } = createMockSandbox();

      // Binding approach: MISSING_CONFIG output
      startProcessMock.mockResolvedValueOnce(createMockProcess('MISSING_CONFIG'));

      const env = createMockEnvWithR2();

      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(false);
      expect(result.error).toBe('Sync aborted: source missing clawdbot.json');
    });

    it('returns error when tar output is too small', async () => {
      const { sandbox, startProcessMock } = createMockSandbox();

      // Binding approach: tiny output (< 100 bytes)
      startProcessMock
        .mockResolvedValueOnce(createMockProcess('abc\nTAR_OK\n'))
        // Fallback: mount check, then rsync fails
        .mockResolvedValueOnce(createMockProcess('')) // mount check - not mounted
        .mockResolvedValueOnce(createMockProcess('')); // rsync

      const env = createMockEnvWithR2();

      const result = await syncToR2(sandbox, env);

      // Should fail on binding (too small), then try fallback which also fails
      expect(result.success).toBe(false);
    });
  });

  describe('fallback s3fs sync', () => {
    it('falls back to rsync when binding approach fails', async () => {
      const { sandbox, startProcessMock } = createMockSandbox();
      const timestamp = '2026-01-27T12:00:00+00:00';

      startProcessMock
        // Binding approach: container error
        .mockRejectedValueOnce(new Error('Container service disconnected'))
        // Fallback: mount check (not mounted)
        .mockResolvedValueOnce(createMockProcess(''))
        // Fallback: single rsync command with timestamp
        .mockResolvedValueOnce(createMockProcess(timestamp));

      const env = createMockEnvWithR2();

      const result = await syncToR2(sandbox, env);

      expect(result.success).toBe(true);
      expect(result.lastSync).toBe(timestamp);
    });

    it('verifies fallback rsync command includes config, skills, and workspace', async () => {
      const { sandbox, startProcessMock } = createMockSandbox();
      const timestamp = '2026-01-27T12:00:00+00:00';

      startProcessMock
        // Binding approach: fails
        .mockRejectedValueOnce(new Error('Container disconnected'))
        // Fallback mount check (not mounted)
        .mockResolvedValueOnce(createMockProcess(''))
        // Fallback rsync
        .mockResolvedValueOnce(createMockProcess(timestamp));

      const env = createMockEnvWithR2();
      await syncToR2(sandbox, env);

      // Third call (index 2) should be the chained rsync command
      const rsyncCall = startProcessMock.mock.calls[2][0];
      expect(rsyncCall).toContain('rsync');
      expect(rsyncCall).toContain('--no-times');
      expect(rsyncCall).toContain('--delete');
      expect(rsyncCall).toContain('/root/.clawdbot/');
      expect(rsyncCall).toContain('/data/moltbot/clawdbot/');
      expect(rsyncCall).toContain('/root/clawd/skills/');
      expect(rsyncCall).toContain('/data/moltbot/skills/');
      expect(rsyncCall).toContain('/root/clawd/');
      expect(rsyncCall).toContain('/data/moltbot/workspace/');
      expect(rsyncCall).toContain("--exclude='node_modules'");
      expect(rsyncCall).toContain("--exclude='.git'");
      expect(rsyncCall).toContain("--exclude='skills'");
    });
  });
});
