#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e
# v2: open DM policy for Google Chat

# Check if clawdbot gateway is already running - bail early if so
# Note: CLI is still named "clawdbot" until upstream renames it
if pgrep -f "clawdbot gateway" > /dev/null 2>&1; then
    echo "Moltbot gateway is already running, exiting."
    exit 0
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"

# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Supports two backup formats:
# 1. Tar-based backup (backup.tar.gz) - created by R2 binding approach
# 2. Directory-based backup (clawdbot/, skills/, workspace/) - created by rsync approach
# The BACKUP_DIR is mounted via s3fs at /data/moltbot

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"

    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi

    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi

    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)

    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"

    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")

    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

SKILLS_DIR="/root/clawd/skills"
WORKSPACE_DIR="/root/clawd"
RESTORED_FROM_TAR=false

# Priority 1: Tar-based backup (from R2 binding approach, most reliable)
# Archive contains: .clawdbot/, skills/, clawd/MEMORY.md, clawd/SOUL.md, etc.
if [ -f "$BACKUP_DIR/backup.tar.gz" ]; then
    if should_restore_from_r2; then
        echo "Restoring from tar backup at $BACKUP_DIR/backup.tar.gz..."
        TEMP_DIR=$(mktemp -d)
        if tar xzf "$BACKUP_DIR/backup.tar.gz" -C "$TEMP_DIR" 2>/dev/null; then
            # Restore config (.clawdbot/ → /root/.clawdbot/)
            if [ -d "$TEMP_DIR/.clawdbot" ]; then
                cp -a "$TEMP_DIR/.clawdbot/." "$CONFIG_DIR/"
                echo "Restored config from tar backup"
            fi
            # Restore skills (skills/ → /root/clawd/skills/)
            if [ -d "$TEMP_DIR/skills" ]; then
                mkdir -p "$SKILLS_DIR"
                cp -a "$TEMP_DIR/skills/." "$SKILLS_DIR/"
                echo "Restored skills from tar backup"
            fi
            # Restore workspace files (clawd/ → /root/clawd/)
            if [ -d "$TEMP_DIR/clawd" ]; then
                mkdir -p "$WORKSPACE_DIR"
                cp -a "$TEMP_DIR/clawd/." "$WORKSPACE_DIR/"
                echo "Restored workspace from tar backup"
            fi
            # Copy sync timestamp
            cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
            RESTORED_FROM_TAR=true
        else
            echo "Failed to extract tar backup, will try directory-based restore"
        fi
        rm -rf "$TEMP_DIR"
    fi
fi

# Safety check: if tar restore produced an empty workspace, fall back to directory restore
if [ "$RESTORED_FROM_TAR" = "true" ] && [ ! -d "$WORKSPACE_DIR/memory" ] && [ ! -f "$WORKSPACE_DIR/SOUL.md" ]; then
    echo "WARNING: Tar restore produced empty workspace, falling through to directory backup"
    RESTORED_FROM_TAR=false
fi

# Priority 2: Directory-based backup (from rsync approach, fallback)
if [ "$RESTORED_FROM_TAR" != "true" ]; then
    if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
        if should_restore_from_r2; then
            echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
            cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
            cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
            echo "Restored config from R2 backup"
        fi
    elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
        # Legacy backup format (flat structure)
        if should_restore_from_r2; then
            echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
            cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
            cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
            echo "Restored config from legacy R2 backup"
        fi
    elif [ -d "$BACKUP_DIR" ]; then
        echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
    else
        echo "R2 not mounted, starting fresh"
    fi

    # Restore skills from directory backup if available
    if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
        if should_restore_from_r2; then
            echo "Restoring skills from $BACKUP_DIR/skills..."
            mkdir -p "$SKILLS_DIR"
            cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
            echo "Restored skills from R2 backup"
        fi
    fi

    # Restore workspace from directory backup if available
    if [ -d "$BACKUP_DIR/workspace" ] && [ "$(ls -A $BACKUP_DIR/workspace 2>/dev/null)" ]; then
        if should_restore_from_r2; then
            echo "Restoring workspace from $BACKUP_DIR/workspace..."
            mkdir -p "$WORKSPACE_DIR"
            rsync -r --exclude='skills' "$BACKUP_DIR/workspace/" "$WORKSPACE_DIR/"
            echo "Restored workspace from R2 backup"
        fi
    fi
fi

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
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5-20251101';
} else {
    // Default to Anthropic without custom base URL (uses built-in pi-ai catalog)
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
console.log('Config:', JSON.stringify(config, null, 2));
EOFNODE

# ============================================================
# IN-CONTAINER BACKUP LOOP
# ============================================================
# Backs up config/skills/workspace to R2 via s3fs mount every 5 minutes.
# This runs inside the container and does NOT depend on the Worker's
# sandbox session or cron trigger — it writes directly to /data/moltbot.
if [ -d "$BACKUP_DIR" ]; then
    (
        # Disable set -e in backup subshell so s3fs errors don't kill the loop
        set +e
        # Initial delay to let the gateway fully start
        sleep 60
        while true; do
            # Only backup if config exists AND workspace has real content
            # (prevents backing up an empty/fresh workspace that would overwrite good data)
            if [ -f "$CONFIG_DIR/clawdbot.json" ]; then
                # Config and skills: use --delete (these are well-defined, safe to mirror)
                rsync -r --no-times --delete --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' \
                    "$CONFIG_DIR/" "$BACKUP_DIR/clawdbot/" 2>/dev/null
                rsync -r --no-times --delete \
                    "$SKILLS_DIR/" "$BACKUP_DIR/skills/" 2>/dev/null
                # Workspace: NO --delete (an incomplete restore must not wipe R2 backup data)
                rsync -r --no-times --exclude='node_modules' --exclude='.git' --exclude='skills' \
                    "$WORKSPACE_DIR/" "$BACKUP_DIR/workspace/" 2>/dev/null

                date -Iseconds > "$BACKUP_DIR/.last-sync" 2>/dev/null
                echo "[container-backup] Synced at $(date -Iseconds)"
            elif [ -f "$CONFIG_DIR/clawdbot.json" ]; then
                echo "[container-backup] Skipping: workspace has no memory/SOUL.md (might be fresh/empty)"
            else
                echo "[container-backup] Skipping: no config file yet"
            fi
            sleep 300
        done
    ) &
    echo "Started in-container backup loop (PID $!)"
else
    echo "No backup dir mounted, skipping in-container backup loop"
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
