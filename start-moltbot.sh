#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores data from R2 mount to local disk (fast)
# 2. Configures moltbot from environment variables
# 3. Starts a background sync loop (local → R2, every 60s)
# 4. Starts the gateway
#
# Architecture: gateway runs on LOCAL disk (fast), background loop
# pushes changes to R2 mount (persistence). No symlinks to s3fs.

# Check if clawdbot gateway is already running - bail early if so
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths
R2_DIR="/r2"
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"

echo "R2 mount: $R2_DIR"

# ============================================================
# RESTORE FROM R2 TO LOCAL DISK
# ============================================================
# R2 is mounted at /r2 via s3fs. We copy data from R2 to local disk
# so the gateway runs at full speed. A background loop syncs back.

if mountpoint -q "$R2_DIR" 2>/dev/null; then
    echo "R2 is mounted at $R2_DIR, restoring config to local disk..."

    # --- Restore essential config files synchronously (fast) ---
    # These 2 files are all the gateway needs to start listening.
    mkdir -p "$CONFIG_DIR"
    if [ -f "$R2_DIR/clawdbot/clawdbot.json" ]; then
        cp "$R2_DIR/clawdbot/clawdbot.json" "$CONFIG_DIR/clawdbot.json" 2>/dev/null || true
        echo "Restored clawdbot.json from R2"
    else
        echo "No clawdbot.json in R2 (first run)"
    fi
    if [ -f "$R2_DIR/clawdbot/google-chat-sa.json" ]; then
        cp "$R2_DIR/clawdbot/google-chat-sa.json" "$CONFIG_DIR/google-chat-sa.json" 2>/dev/null || true
        echo "Restored google-chat-sa.json from R2"
    fi

    # --- Restore everything else in background (slow over s3fs) ---
    # Agents dir has conversation sessions, workspace has MEMORY.md, IDENTITY.md, etc.
    # Runs concurrently with gateway startup so it doesn't block port readiness.
    (
        echo "[restore] Starting background restore..."
        rsync -a "$R2_DIR/clawdbot/" "$CONFIG_DIR/" 2>/dev/null || \
            cp -a "$R2_DIR/clawdbot/." "$CONFIG_DIR/" 2>/dev/null || true
        echo "[restore] Config directory restored (agents, memory, credentials, etc.)"
        if [ -d "$R2_DIR/workspace" ]; then
            rsync -a --exclude='node_modules' --exclude='skills' \
                "$R2_DIR/workspace/" "$WORKSPACE_DIR/" 2>/dev/null || \
                cp -a "$R2_DIR/workspace/." "$WORKSPACE_DIR/" 2>/dev/null || true
            echo "[restore] Workspace restored (MEMORY.md, IDENTITY.md, etc.)"
        fi
        mkdir -p "$SKILLS_DIR"
        echo "[restore] Listing $R2_DIR/workspace/skills/:"
        ls -la "$R2_DIR/workspace/skills/" 2>&1 || echo "[restore] skills dir listing failed"
        if rsync -av "$R2_DIR/workspace/skills/" "$SKILLS_DIR/" 2>&1; then
            echo "[restore] Skills restored via rsync"
        elif cp -av "$R2_DIR/workspace/skills/." "$SKILLS_DIR/" 2>&1; then
            echo "[restore] Skills restored via cp"
        else
            echo "[restore] Skills restore FAILED"
        fi
        echo "[restore] Background restore complete"
    ) &
    echo "Started background restore (PID $!)"

    echo "Restore complete, gateway will run on local disk"
else
    echo "WARNING: R2 not mounted at $R2_DIR, running without persistence"
fi

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}

// Strip invalid plugin load paths (prevents startup crash if plugin files are missing)
if (config.plugins?.load?.paths) {
    const validPaths = config.plugins.load.paths.filter(p => {
        const exists = fs.existsSync(p);
        if (!exists) console.log('Removing missing plugin path:', p);
        return exists;
    });
    config.plugins.load.paths = validPaths;
    if (validPaths.length === 0) delete config.plugins.load;
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    config.channels.telegram.dm = config.channels.telegram.dm || {};
    config.channels.telegram.dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Google Chat configuration
if (process.env.GOOGLE_CHAT_SERVICE_ACCOUNT) {
    config.channels.googlechat = config.channels.googlechat || {};
    // Write service account JSON to file (OpenClaw expects a file path)
    const saPath = '/root/.clawdbot/google-chat-sa.json';
    try {
        const saJson = JSON.parse(process.env.GOOGLE_CHAT_SERVICE_ACCOUNT);
        require('fs').writeFileSync(saPath, JSON.stringify(saJson, null, 2));
        config.channels.googlechat.serviceAccountFile = saPath;
        console.log('Wrote Google Chat service account to', saPath);
    } catch (e) {
        console.error('Failed to parse GOOGLE_CHAT_SERVICE_ACCOUNT as JSON:', e.message);
    }
    if (process.env.GOOGLE_CHAT_AUDIENCE) {
        config.channels.googlechat.audience = process.env.GOOGLE_CHAT_AUDIENCE;
    }
    if (process.env.GOOGLE_CHAT_AUDIENCE_TYPE) {
        config.channels.googlechat.audienceType = process.env.GOOGLE_CHAT_AUDIENCE_TYPE;
    }
    config.channels.googlechat.webhookPath = '/googlechat';
    config.channels.googlechat.dm = config.channels.googlechat.dm || {};
    config.channels.googlechat.dm.policy = 'open';
    config.channels.googlechat.dm.allowFrom = ['*'];
    config.channels.googlechat.enabled = true;
}

// Base URL override (e.g., for Cloudflare AI Gateway)
// Usage: Set AI_GATEWAY_BASE_URL or ANTHROPIC_BASE_URL to your endpoint like:
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/anthropic
//   https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/openai
const baseUrl = (process.env.AI_GATEWAY_BASE_URL || process.env.ANTHROPIC_BASE_URL || '').replace(/\/+$/, '');
const isOpenAI = baseUrl.endsWith('/openai');

if (isOpenAI) {
    // Create custom openai provider config with baseUrl override
    // Omit apiKey so moltbot falls back to OPENAI_API_KEY env var
    console.log('Configuring OpenAI provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    config.models.providers.openai = {
        baseUrl: baseUrl,
        api: 'openai-responses',
        models: [
            { id: 'gpt-5.2', name: 'GPT-5.2', contextWindow: 200000 },
            { id: 'gpt-5', name: 'GPT-5', contextWindow: 200000 },
            { id: 'gpt-4.5-preview', name: 'GPT-4.5 Preview', contextWindow: 128000 },
        ]
    };
    // Add models to the allowlist so they appear in /models
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['openai/gpt-5.2'] = { alias: 'GPT-5.2' };
    config.agents.defaults.models['openai/gpt-5'] = { alias: 'GPT-5' };
    config.agents.defaults.models['openai/gpt-4.5-preview'] = { alias: 'GPT-4.5' };
    config.agents.defaults.model.primary = 'openai/gpt-5.2';
} else if (baseUrl) {
    console.log('Configuring Anthropic provider with base URL:', baseUrl);
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};
    const providerConfig = {
        baseUrl: baseUrl,
        api: 'anthropic-messages',
        models: [
            { id: 'claude-opus-4-5-20251101', name: 'Claude Opus 4.5', contextWindow: 200000 },
            { id: 'claude-sonnet-4-5-20250929', name: 'Claude Sonnet 4.5', contextWindow: 200000 },
            { id: 'claude-haiku-4-5-20251001', name: 'Claude Haiku 4.5', contextWindow: 200000 },
        ]
    };
    // Include API key in provider config if set (required when using custom baseUrl)
    if (process.env.ANTHROPIC_API_KEY) {
        providerConfig.apiKey = process.env.ANTHROPIC_API_KEY;
    }
    config.models.providers.anthropic = providerConfig;
    // Add models to the allowlist so they appear in /models
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['anthropic/claude-opus-4-5-20251101'] = { alias: 'Opus 4.5' };
    config.agents.defaults.models['anthropic/claude-sonnet-4-5-20250929'] = { alias: 'Sonnet 4.5' };
    config.agents.defaults.models['anthropic/claude-haiku-4-5-20251001'] = { alias: 'Haiku 4.5' };
    config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5-20250929';
} else {
    // Default to Anthropic without custom base URL (uses built-in pi-ai catalog)
    config.agents.defaults.model.primary = 'anthropic/claude-sonnet-4-5';
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# BACKGROUND SYNC: LOCAL DISK → R2
# ============================================================
# Pushes changes from local disk to R2 mount every 60 seconds.
# No --delete: only adds/updates, never removes from R2.
if mountpoint -q "$R2_DIR" 2>/dev/null; then
    (
        set +e
        sleep 30
        while true; do
            if [ -f "$CONFIG_DIR/clawdbot.json" ]; then
                rsync -a --no-times --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' \
                    "$CONFIG_DIR/" "$R2_DIR/clawdbot/" 2>/dev/null
                rsync -a --no-times --exclude='node_modules' --exclude='.git' --exclude='skills' \
                    "$WORKSPACE_DIR/" "$R2_DIR/workspace/" 2>/dev/null
                rsync -a --no-times \
                    "$SKILLS_DIR/" "$R2_DIR/workspace/skills/" 2>/dev/null
                date -Iseconds > "$R2_DIR/.last-sync" 2>/dev/null
                echo "[sync] Pushed to R2 at $(date -Iseconds)"
            fi
            sleep 60
        done
    ) &
    echo "Started background sync loop (PID $!)"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

BIND_MODE="lan"
echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}, Bind mode: $BIND_MODE"

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE" --token "$CLAWDBOT_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec clawdbot gateway --port 18789 --verbose --allow-unconfigured --bind "$BIND_MODE"
fi
