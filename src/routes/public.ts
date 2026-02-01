import { Hono } from 'hono';
import type { AppEnv } from '../types';
import { MOLTBOT_PORT } from '../config';
import { findExistingMoltbotProcess, ensureMoltbotGateway } from '../gateway';

/**
 * Public routes - NO Cloudflare Access authentication required
 * 
 * These routes are mounted BEFORE the auth middleware is applied.
 * Includes: health checks, static assets, and public API endpoints.
 */
const publicRoutes = new Hono<AppEnv>();

// GET /sandbox-health - Health check endpoint
publicRoutes.get('/sandbox-health', (c) => {
  return c.json({
    status: 'ok',
    service: 'moltbot-sandbox',
    gateway_port: MOLTBOT_PORT,
  });
});

// GET /logo.png - Serve logo from ASSETS binding
publicRoutes.get('/logo.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /logo-small.png - Serve small logo from ASSETS binding
publicRoutes.get('/logo-small.png', (c) => {
  return c.env.ASSETS.fetch(c.req.raw);
});

// GET /api/status - Public health check for gateway status (no auth required)
publicRoutes.get('/api/status', async (c) => {
  const sandbox = c.get('sandbox');
  
  try {
    const process = await findExistingMoltbotProcess(sandbox);
    if (!process) {
      return c.json({ ok: false, status: 'not_running' });
    }
    
    // Process exists, check if it's actually responding
    // Try to reach the gateway with a short timeout
    try {
      await process.waitForPort(18789, { mode: 'tcp', timeout: 5000 });
      return c.json({ ok: true, status: 'running', processId: process.id });
    } catch {
      return c.json({ ok: false, status: 'not_responding', processId: process.id });
    }
  } catch (err) {
    return c.json({ ok: false, status: 'error', error: err instanceof Error ? err.message : 'Unknown error' });
  }
});

// GET /_admin/assets/* - Admin UI static assets (CSS, JS need to load for login redirect)
// Assets are built to dist/client with base "/_admin/"
publicRoutes.get('/_admin/assets/*', async (c) => {
  const url = new URL(c.req.url);
  // Rewrite /_admin/assets/* to /assets/* for the ASSETS binding
  const assetPath = url.pathname.replace('/_admin/assets/', '/assets/');
  const assetUrl = new URL(assetPath, url.origin);
  return c.env.ASSETS.fetch(new Request(assetUrl.toString(), c.req.raw));
});

// GET /googlechat/health - Diagnostic endpoint for Google Chat channel
// Returns gateway channel health, process logs, and config diagnostics
publicRoutes.get('/googlechat/health', async (c) => {
  const sandbox = c.get('sandbox');
  const diagnostics: Record<string, unknown> = { timestamp: new Date().toISOString() };

  // Check gateway process
  try {
    const process = await findExistingMoltbotProcess(sandbox);
    diagnostics.gateway = process
      ? { status: process.status, id: process.id }
      : { status: 'not_running' };

    if (process) {
      // Get process logs (last portion)
      try {
        const logs = await process.getLogs();
        const stdout = logs.stdout || '';
        const stderr = logs.stderr || '';
        // Only include last 2000 chars of each
        diagnostics.logs = {
          stdout: stdout.slice(-2000),
          stderr: stderr.slice(-2000),
        };
      } catch { diagnostics.logs = 'failed to retrieve'; }

      // Probe gateway channels health API
      try {
        const healthUrl = `http://localhost:${MOLTBOT_PORT}/api/health/channels`;
        const resp = await sandbox.containerFetch(new Request(healthUrl), MOLTBOT_PORT);
        if (resp.ok) {
          diagnostics.channelsHealth = await resp.json();
        } else {
          diagnostics.channelsHealth = { status: resp.status, body: await resp.text().catch(() => '') };
        }
      } catch (e) { diagnostics.channelsHealth = { error: e instanceof Error ? e.message : 'unknown' }; }
    }
  } catch (e) {
    diagnostics.error = e instanceof Error ? e.message : 'unknown';
  }

  // Read config to check channel settings (redact secrets)
  try {
    const proc = await sandbox.startProcess('cat /root/.clawdbot/clawdbot.json');
    let attempts = 0;
    while (proc.status === 'running' && attempts < 10) {
      await new Promise(r => setTimeout(r, 200));
      attempts++;
    }
    const logs = await proc.getLogs();
    try {
      const config = JSON.parse(logs.stdout || '');
      // Redact secrets
      if (config.gateway?.auth?.token) config.gateway.auth.token = '(redacted)';
      if (config.channels?.googlechat?.serviceAccountFile) config.channels.googlechat.serviceAccountFile = '(path set)';
      if (config.channels?.googlechat?.serviceAccount) config.channels.googlechat.serviceAccount = '(redacted)';
      if (config.models?.providers?.anthropic?.apiKey) config.models.providers.anthropic.apiKey = '(redacted)';
      diagnostics.config = {
        channels: config.channels,
        model: config.agents?.defaults?.model,
        models: config.agents?.defaults?.models,
        providers: config.models?.providers ? Object.fromEntries(
          Object.entries(config.models.providers).map(([k, v]: [string, any]) => [k, { baseUrl: v.baseUrl, api: v.api, models: v.models?.map((m: any) => m.name || m.id) }])
        ) : undefined,
      };
    } catch { diagnostics.config = { raw: (logs.stdout || '').slice(0, 500) }; }
  } catch (e) { diagnostics.config = { error: e instanceof Error ? e.message : 'unknown' }; }

  return c.json(diagnostics);
});

// GET /googlechat/debug-sync - Debug endpoint to check R2 mount status
publicRoutes.get('/googlechat/debug-sync', async (c) => {
  const sandbox = c.get('sandbox');
  const steps: Record<string, unknown> = { timestamp: new Date().toISOString() };

  // Check R2 credentials
  steps.credentials = {
    hasR2AccessKey: !!c.env.R2_ACCESS_KEY_ID,
    hasR2SecretKey: !!c.env.R2_SECRET_ACCESS_KEY,
    hasCfAccountId: !!c.env.CF_ACCOUNT_ID,
  };

  // Check gateway via containerFetch (doesn't need sandbox session)
  try {
    const healthUrl = `http://localhost:${MOLTBOT_PORT}/api/health`;
    const resp = await sandbox.containerFetch(new Request(healthUrl), MOLTBOT_PORT);
    steps.gatewayHealth = { status: resp.status, ok: resp.ok };
  } catch (e) { steps.gatewayHealth = { error: e instanceof Error ? e.message : 'unknown' }; }

  // Check cron heartbeat (verifies cron is firing)
  try {
    const obj = await c.env.MOLTBOT_BUCKET.get('.cron-heartbeat');
    if (obj) {
      steps.cronHeartbeat = { found: true, content: await obj.text() };
    } else {
      steps.cronHeartbeat = { found: false };
    }
  } catch (e) { steps.cronHeartbeat = { error: e instanceof Error ? e.message : 'unknown' }; }

  // List R2 objects (supports ?prefix= query param, default lists all)
  try {
    const prefix = new URL(c.req.url).searchParams.get('prefix') || undefined;
    const allObjects: { key: string; size: number; uploaded?: string }[] = [];
    let cursor: string | undefined;
    do {
      const list = await c.env.MOLTBOT_BUCKET.list({ limit: 500, prefix, cursor });
      for (const o of list.objects) {
        allObjects.push({ key: o.key, size: o.size, uploaded: o.uploaded?.toISOString() });
      }
      cursor = list.truncated ? list.cursor : undefined;
    } while (cursor);
    steps.r2Objects = allObjects;
    steps.r2ObjectCount = allObjects.length;
  } catch (e) { steps.r2Objects = { error: e instanceof Error ? e.message : 'unknown' }; }

  return c.json(steps);
});


// POST /googlechat - Google Chat webhook endpoint (public, no CF Access auth)
// Google Chat sends HTTP POST requests to this webhook when messages arrive.
// Authentication is handled by OpenClaw using the Google Chat service account credentials.
publicRoutes.post('/googlechat', async (c) => {
  const sandbox = c.get('sandbox');

  try {
    await ensureMoltbotGateway(sandbox, c.env);
  } catch (error) {
    console.error('[WEBHOOK] Failed to start gateway for Google Chat webhook:', error);
    return c.json({ error: 'Gateway not available' }, 503);
  }

  const response = await sandbox.containerFetch(c.req.raw, MOLTBOT_PORT);

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers,
  });
});

export { publicRoutes };
