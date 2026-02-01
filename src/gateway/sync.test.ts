import { describe, it, expect, beforeEach } from 'vitest';
import { syncToR2 } from './sync';
import {
  createMockEnv,
  createMockEnvWithR2,
  createMockSandbox,
  suppressConsole
} from '../test-utils';

describe('syncToR2', () => {
  beforeEach(() => {
    suppressConsole();
  });

  it('returns success with direct R2 mount (no-op)', async () => {
    const { sandbox } = createMockSandbox();
    const env = createMockEnvWithR2();

    const result = await syncToR2(sandbox, env);

    expect(result.success).toBe(true);
    expect(result.lastSync).toMatch(/^\d{4}-\d{2}-\d{2}/);
    expect(result.details).toBe('Direct R2 mount - no sync needed');
  });

  it('returns success even without R2 configured (no-op)', async () => {
    const { sandbox } = createMockSandbox();
    const env = createMockEnv();

    const result = await syncToR2(sandbox, env);

    expect(result.success).toBe(true);
    expect(result.lastSync).toMatch(/^\d{4}-\d{2}-\d{2}/);
    expect(result.details).toBe('Direct R2 mount - no sync needed');
  });

  it('does not make any sandbox calls (true no-op)', async () => {
    const { sandbox, startProcessMock } = createMockSandbox();
    const env = createMockEnvWithR2();

    await syncToR2(sandbox, env);

    // Verify no sandbox interactions occurred
    expect(startProcessMock).not.toHaveBeenCalled();
  });
});
