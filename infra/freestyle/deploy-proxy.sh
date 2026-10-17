#!/usr/bin/env bash
# Deploys proxy/server.mjs to a Freestyle VM and publishes it at
# https://<SLUG>.style.dev. Re-running updates the code and restarts the service.
#
#   infra/freestyle/deploy-proxy.sh            # uses infra/freestyle/.env.proxy
#   SLUG=echoguide-proxy-bryan infra/freestyle/deploy-proxy.sh
#
# .env.proxy holds the proxy's environment (see proxy/server.mjs header):
#   DEVICE_TOKEN_SHA256S=<sha256 of each device token, comma separated>
#   GEMINI_API_KEY=... DEEPGRAM_API_KEY=... ELEVENLABS_API_KEY=...
# It is git-ignored and never leaves this folder except onto the VM.
set -euo pipefail
cd "$(dirname "$0")/../.."

SLUG="${SLUG:-echoguide-proxy}"
DOMAIN="${DOMAIN:-$SLUG.style.dev}"
PORT=8787
ENV_FILE="${ENV_FILE:-infra/freestyle/.env.proxy}"
FS="npx -y freestyle@latest"

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy infra/freestyle/.env.proxy.example)"; exit 1; }
grep -q '^DEVICE_TOKEN_SHA256S=.\+' "$ENV_FILE" || { echo "$ENV_FILE needs DEVICE_TOKEN_SHA256S"; exit 1; }

# 1. VM: a zero-dependency Node proxy needs the small Ubuntu image.
if ! $FS --output json vm get "$SLUG" >/dev/null 2>&1; then
  echo "creating VM $SLUG"
  $FS vm create --slug "$SLUG" --snapshot-id freestyle/ubuntu-sm --no-ssh \
    --display-name "EchoGuide key proxy" --metadata app=echoguide --metadata role=proxy >/dev/null
fi
$FS vm start "$SLUG" >/dev/null 2>&1 || true

# 2. Code and environment.
$FS vm exec "$SLUG" --linux-user root -- mkdir -p /srv/echoguide-proxy
$FS vm fs write "$SLUG" /srv/echoguide-proxy/server.mjs proxy/server.mjs
$FS vm fs write "$SLUG" /srv/echoguide-proxy/package.json proxy/package.json
$FS vm fs write "$SLUG" /srv/echoguide-proxy/.env "$ENV_FILE"
$FS vm exec "$SLUG" --linux-user root -- chmod 600 /srv/echoguide-proxy/.env

# 3. systemd unit. Node is under nvm on the Ubuntu image; use the absolute path.
NODE=$($FS vm exec "$SLUG" --linux-user root -- sh -c 'ls /usr/local/nvm/versions/node/*/bin/node 2>/dev/null | head -1 || command -v node' | tr -d '\r\n')
[ -n "$NODE" ] || { echo "node not found on VM"; exit 1; }
UNIT=$(mktemp)
cat > "$UNIT" <<UNIT
[Unit]
Description=EchoGuide key proxy
After=network.target

[Service]
ExecStart=$NODE /srv/echoguide-proxy/server.mjs
WorkingDirectory=/srv/echoguide-proxy
EnvironmentFile=/srv/echoguide-proxy/.env
Environment=PORT=$PORT
Environment=HOME=/root
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT
$FS vm fs write "$SLUG" /etc/systemd/system/echoguide-proxy.service "$UNIT"
rm -f "$UNIT"
$FS vm exec "$SLUG" --linux-user root -- sh -c 'systemctl daemon-reload && systemctl enable --now echoguide-proxy && systemctl restart echoguide-proxy'

# 4. Wait for it, then publish.
for i in $(seq 1 30); do
  CODE=$($FS vm exec "$SLUG" --linux-user root -- python3 -c "import urllib.request,sys
try: print(urllib.request.urlopen('http://localhost:$PORT/healthz',timeout=5).status)
except Exception as e: print(getattr(e,'code',0))" | tr -d '\r\n')
  case "$CODE" in 2*|4*) break;; esac
  sleep 1
done
echo "proxy answers locally with HTTP $CODE"

if ! $FS --output json tls list --vm "$SLUG" 2>/dev/null | grep -q "\"$DOMAIN\""; then
  $FS tls create --domain "$DOMAIN" --from public --to "vm=$SLUG,port=$PORT" >/dev/null
fi
echo
echo "proxy:  https://$DOMAIN"
echo "Set EGProxyBaseURL in EchoGuideApp/Info.plist to that URL (Maxwell's file)."
echo "Snapshot it once it works:  npx -y freestyle@latest snapshot create $SLUG --slug $SLUG-ok"
