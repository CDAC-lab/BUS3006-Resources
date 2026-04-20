#!/usr/bin/env bash
#
# OpenClaw student VPS setup — one script, everything in one go.
#
# What this does:
#   1. Makes your OpenClaw dashboard reachable over HTTPS via sslip.io + Caddy
#      (no signup, no DNS, no credentials — fully automatic).
#   2. Asks up front whether you're using the instructor's shared workshop
#      key or your own OpenAI/Anthropic key, then walks you through the
#      wizard with the right answers.
#   3. For the instructor key, locks the model to GPT-5-nano so shared
#      class budget is not accidentally burned on a bigger model.
#      For your own key, respects whatever you picked in the wizard.
#   4. Auto-approves the pairing request when you open the dashboard.
#   5. Verifies everything and prints a final "all good" summary.
#
# Assumes: OpenClaw is already installed on this VPS (the Kamatera image
# does that for you).
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/CDAC-lab/BUS3006-Resources/main/openclaw-student-setup.sh -o setup.sh
#   sudo bash setup.sh
#
# Optional environment variables:
#   OPENCLAW_PORT      Local OpenClaw port (default: 18789)
#   OPENCLAW_CONFIG    Config path (default: /root/.openclaw/openclaw.json)
#   OPENCLAW_MODEL     Model to pin. Defaults to openai/gpt-5-nano for the
#                      instructor key, and empty (no override) for own key.
#   PAIRING_TIMEOUT    Seconds to wait for browser pairing (default: 600)

set -euo pipefail

# ---------------------------------------------------------------------------
# sanity checks
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run this as root (or with sudo)."
    exit 1
fi

if ! command -v openclaw >/dev/null; then
    echo "ERROR: the 'openclaw' command wasn't found."
    echo "If OpenClaw is installed, check that it's on your PATH."
    exit 1
fi

OPENCLAW_PORT="${OPENCLAW_PORT:-18789}"
OPENCLAW_CONFIG="${OPENCLAW_CONFIG:-/root/.openclaw/openclaw.json}"
PAIRING_TIMEOUT="${PAIRING_TIMEOUT:-600}"

# ---------------------------------------------------------------------------
# key mode: instructor (locked to gpt-5-nano) or own (no override)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Which API key are you about to use?"
echo "============================================================"
echo "  Your own key  -> recommended. Pick any model you like."
echo "                   OpenAI sk-... or Anthropic sk-ant-..."
echo "  Workshop key  -> shared class key. Pinned to gpt-5-nano"
echo "                   so the shared budget lasts the workshop."
echo ""

KEY_MODE=""
while [[ -z "$KEY_MODE" ]]; do
    read -rp "Are you using the instructor's workshop key? [y/N] " ans < /dev/tty
    case "${ans,,}" in
        y|yes)
            KEY_MODE="instructor"
            ;;
        n|no|"")
            KEY_MODE="own"
            ;;
        *)
            echo "Please answer y or n."
            ;;
    esac
done

case "$KEY_MODE" in
    instructor)
        OPENCLAW_MODEL="${OPENCLAW_MODEL:-openai/gpt-5-nano}"
        echo "  Mode: instructor key. Model will be locked to ${OPENCLAW_MODEL}."
        ;;
    own)
        OPENCLAW_MODEL="${OPENCLAW_MODEL:-}"
        echo "  Mode: own key. Whatever you pick in the wizard will stick."
        ;;
esac

# ---------------------------------------------------------------------------
# step 1: detect public IP
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  STEP 1/7 - Finding your VPS's public IP address"
echo "============================================================"
IP=""
for service in ifconfig.co ifconfig.me icanhazip.com api.ipify.org; do
    IP=$(curl -s --max-time 5 "https://${service}" || true)
    [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    IP=""
done
[[ -z "$IP" ]] && { echo "ERROR: couldn't detect your public IP."; exit 1; }
HOSTNAME="${IP//./-}.sslip.io"
URL="https://${HOSTNAME}"
echo "  IP:       ${IP}"
echo "  Hostname: ${HOSTNAME}"
echo "  Dashboard will live at: ${URL}"

# ---------------------------------------------------------------------------
# step 2: install Caddy + jq
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  STEP 2/7 - Installing Caddy (gives you a real HTTPS cert)"
echo "============================================================"

# The Kamatera image ships with nginx on ports 80/443 serving a
# wildcard cert for *.au-sy-cloud-xip.com (that's what caused the
# original "not private" browser warning). We have to evict it
# before Caddy can bind.
if systemctl is-active --quiet nginx 2>/dev/null; then
    echo "  Stopping the pre-installed nginx (it's hogging ports 80/443)..."
    systemctl stop nginx || true
    systemctl disable nginx 2>/dev/null || true
    echo "  nginx stopped and disabled."
fi

# Belt-and-suspenders: make sure nothing else is on 80/443 either.
if ss -tln 2>/dev/null | grep -qE ':(80|443)\s'; then
    echo ""
    echo "WARNING: something else is still listening on port 80 or 443."
    echo "         Caddy will fail to start. Run this to see what:"
    echo "             ss -tlnp | grep -E ':(80|443)\\s'"
fi

apt-get update -qq
apt-get install -y -qq debian-keyring debian-archive-keyring \
    apt-transport-https curl gnupg jq

if ! command -v caddy >/dev/null; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq
    apt-get install -y -qq caddy
fi

cat > /etc/caddy/Caddyfile <<EOF
${HOSTNAME} {
    reverse_proxy 127.0.0.1:${OPENCLAW_PORT}
}
EOF

echo "  Caddy installed and configured."

# ---------------------------------------------------------------------------
# step 3: allow the new URL inside OpenClaw
# ---------------------------------------------------------------------------
if [[ -f "$OPENCLAW_CONFIG" ]]; then
    echo ""
    echo "============================================================"
    echo "  STEP 3/7 - Telling OpenClaw to accept requests from ${URL}"
    echo "============================================================"
    tmp=$(mktemp)
    jq --arg url "$URL" --arg url_slash "$URL/" '
        .gateway.controlUi.allowedOrigins = (
            ((.gateway.controlUi.allowedOrigins // []) + [$url, $url_slash]) | unique
        )
    ' "$OPENCLAW_CONFIG" > "$tmp" && mv "$tmp" "$OPENCLAW_CONFIG"
    echo "  Done."
else
    echo ""
    echo "WARNING: OpenClaw config not found at ${OPENCLAW_CONFIG}."
    echo "         Skipping the allowed-origins patch."
fi

# ---------------------------------------------------------------------------
# step 4: start Caddy -> Let's Encrypt cert
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  STEP 4/7 - Starting Caddy and getting a free HTTPS cert"
echo "============================================================"
systemctl restart caddy
echo "  Waiting ~10 seconds for the cert..."
sleep 10
echo "  Done. ${URL} should now serve HTTPS."

# ---------------------------------------------------------------------------
# step 5: API key via the wizard (instructions branch by key mode)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  STEP 5/7 - Adding your API key"
echo "============================================================"

if [[ "$KEY_MODE" == "instructor" ]]; then
    cat <<EOF
The OpenClaw wizard will launch next. Use these answers:

  Where will the Gateway run?    -> Local (this machine)
  Select sections to configure   -> Model
  Model/auth provider            -> OpenAI
  OpenAI auth method             -> OpenAI API key
                                     (if asked; some wizard
                                     versions skip straight
                                     to the key prompt)
  Enter OpenAI API key           -> paste the workshop key
                                     your instructor gave you
                                     (starts with sk-...)
  Models in the /model picker    -> just press Enter
                                     (this script will
                                     overwrite it anyway)
  Select sections to configure   -> Continue

Press Enter when you're ready to launch the wizard...
EOF
else
    cat <<EOF
The OpenClaw wizard will launch next. Use these answers:

  Where will the Gateway run?    -> Local (this machine)
  Select sections to configure   -> Model
  Model/auth provider            -> OpenAI (for sk-... keys)
                                     or Anthropic (for sk-ant-... keys)
  Auth method                    -> API key (if asked)
  Enter API key                  -> paste the key you created
                                     in Step 5b of the workshop
                                     doc
  Models in the /model picker    -> type the model you want,
                                     e.g.
                                       OpenAI:    gpt-5
                                                  gpt-5.1
                                       Anthropic: claude-sonnet-4-6
                                                  claude-opus-4-6
  Select sections to configure   -> Continue

This script will NOT overwrite your choice.

Press Enter when you're ready to launch the wizard...
EOF
fi

read -r _ < /dev/tty

openclaw configure --section models < /dev/tty

# ---------------------------------------------------------------------------
# step 6: lock the model (only if key mode says so)
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
if [[ -n "$OPENCLAW_MODEL" ]]; then
    echo "  STEP 6/7 - Locking the model to ${OPENCLAW_MODEL}"
else
    echo "  STEP 6/7 - Checking the model you configured"
fi
echo "============================================================"

if [[ ! -f "$OPENCLAW_CONFIG" ]]; then
    echo "ERROR: OpenClaw config not found at ${OPENCLAW_CONFIG}."
    echo "       Did the wizard fail? Re-run this script."
    exit 1
fi

if [[ -n "$OPENCLAW_MODEL" ]]; then
    tmp=$(mktemp)
    jq --arg m "$OPENCLAW_MODEL" '
        .agents.defaults.models = {($m): {}} |
        .agents.defaults.model.primary = $m |
        .agents.defaults.model.fallbacks = []
    ' "$OPENCLAW_CONFIG" > "$tmp" && mv "$tmp" "$OPENCLAW_CONFIG"
    echo "  Config updated."
    echo "  Restarting OpenClaw gateway..."
    openclaw gateway restart 2>/dev/null \
        || systemctl --user restart openclaw-gateway 2>/dev/null \
        || true
    sleep 3
else
    echo "  Own-key mode. Leaving the wizard's model choice alone."
fi

# ---- verify the model settings actually stuck ----
echo ""
echo "  Verifying..."
PRIMARY=$(jq -r '.agents.defaults.model.primary // empty' "$OPENCLAW_CONFIG")
ALLOWED=$(jq -r '.agents.defaults.models | keys | join(", ")' "$OPENCLAW_CONFIG")
FALLBACKS=$(jq -r '.agents.defaults.model.fallbacks | if length == 0 then "(none)" else join(", ") end' "$OPENCLAW_CONFIG")

echo "    Default model:  ${PRIMARY:-(unset)}"
echo "    Allowed models: ${ALLOWED:-(unset)}"
echo "    Fallbacks:      ${FALLBACKS}"

if [[ -n "$OPENCLAW_MODEL" ]]; then
    if [[ "$PRIMARY" == "$OPENCLAW_MODEL" ]]; then
        echo "  [OK] Model is pinned to ${OPENCLAW_MODEL}."
    else
        echo "  [!!] Model pin did not take. Expected ${OPENCLAW_MODEL}, got ${PRIMARY}."
        echo "       Please tell your instructor before running any commands."
    fi
else
    if [[ -n "$PRIMARY" ]]; then
        echo "  [OK] Using your chosen model: ${PRIMARY}."
    else
        echo "  [!!] No model is set. Re-run 'openclaw configure --section models'."
    fi
fi

# ---------------------------------------------------------------------------
# step 7: print the URL and auto-approve pairing
# ---------------------------------------------------------------------------
# Pull the gateway token so we can print a one-click URL.
TOKEN=""
TOKEN=$(jq -r '.gateway.auth.token // empty' "$OPENCLAW_CONFIG" 2>/dev/null || true)
if [[ -n "$TOKEN" ]]; then
    FULL_URL="${URL}/?token=${TOKEN}"
else
    FULL_URL="${URL}/"
fi

cat <<EOF

============================================================
  STEP 7/7 - Open your dashboard and pair your browser
============================================================
Your OpenClaw dashboard is ready at:

    ${FULL_URL}

1. Copy that URL and open it in your browser.
2. Your browser will show up as a "pending" device on this VPS.
3. THIS SCRIPT will automatically approve it — you don't
   need to click anything in SSH.
4. Refresh the page once and you're in.

Waiting for you to open the URL (up to $((PAIRING_TIMEOUT / 60)) minutes)...
(Press Ctrl+C only if you want to stop and approve manually later.)
============================================================
EOF

# Poll devices list and approve any pending UUID-shaped request IDs.
# Keep polling even after the first approval — if the student opens the
# URL on more than one browser, each one gets approved.
ELAPSED=0
APPROVED_COUNT=0
LAST_ANNOUNCE=0
while [[ $ELAPSED -lt $PAIRING_TIMEOUT ]]; do
    PENDING_OUTPUT=$(openclaw devices list 2>&1 || true)
    PENDING_IDS=$(echo "$PENDING_OUTPUT" \
        | sed -n '/^Pending/,/^Paired/p' \
        | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        | sort -u || true)

    if [[ -n "$PENDING_IDS" ]]; then
        for id in $PENDING_IDS; do
            echo ""
            echo "  Approving pairing request: $id"
            openclaw devices approve "$id" 2>&1 || true
            APPROVED_COUNT=$((APPROVED_COUNT + 1))
        done
        echo ""
        echo "  [OK] ${APPROVED_COUNT} browser(s) paired so far."
        echo "       Refresh your browser to log in."
        echo "       Still polling in case you open another browser..."
    fi

    # every minute, reassure the student the script is still alive
    if (( ELAPSED - LAST_ANNOUNCE >= 60 )); then
        echo "  ...still waiting (${ELAPSED}s elapsed). Open ${FULL_URL} to pair."
        LAST_ANNOUNCE=$ELAPSED
    fi

    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# ---------------------------------------------------------------------------
# final summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  ALL DONE"
echo "============================================================"
echo ""
echo "Dashboard:      ${FULL_URL}"
echo "Key mode:       ${KEY_MODE}"
if [[ -n "$OPENCLAW_MODEL" ]]; then
    echo "Model (pinned): ${OPENCLAW_MODEL}"
else
    echo "Model:          ${PRIMARY:-(unset)} (your choice, not overridden)"
fi
echo "Devices paired: ${APPROVED_COUNT}"
echo ""

if [[ $APPROVED_COUNT -eq 0 ]]; then
    cat <<EOF
You didn't open the dashboard in time, but that's fine.
You can pair manually later with these commands:

    openclaw devices list
    openclaw devices approve <request-id>

Or just re-run this script.
EOF
fi

echo ""
echo "Useful commands:"
echo "    openclaw devices list                      # see paired browsers"
echo "    sudo journalctl -u caddy -f                # Caddy live log"
echo "    journalctl --user -u openclaw-gateway -f   # OpenClaw live log"
echo "============================================================"
