#!/usr/bin/env bash
# Runs the open-weight Kokoro voice (Kokoro-FastAPI, CPU image) on a Freestyle
# VM and publishes it at https://<SLUG>.style.dev. The app's
# KokoroSpeechProvider(baseURL:) takes that URL unchanged.
#
#   infra/freestyle/deploy-kokoro.sh
#   SLUG=echoguide-voice-bryan infra/freestyle/deploy-kokoro.sh
set -euo pipefail

SLUG="${SLUG:-echoguide-voice}"
DOMAIN="${DOMAIN:-$SLUG.style.dev}"
PORT=8880
IMAGE="${IMAGE:-ghcr.io/remsky/kokoro-fastapi-cpu:latest}"
FS="npx -y freestyle@latest"

# Default Ubuntu image: 4 vCPU / 8 GiB, Docker running from boot.
if ! $FS --output json vm get "$SLUG" >/dev/null 2>&1; then
  echo "creating VM $SLUG"
  $FS vm create --slug "$SLUG" --snapshot-id freestyle/ubuntu --no-ssh \
    --display-name "EchoGuide Kokoro voice" --metadata app=echoguide --metadata role=voice >/dev/null
fi
$FS vm start "$SLUG" >/dev/null 2>&1 || true
# Kokoro's CPU inference is multi-threaded: 8 vCPU halves phrase latency
# (0.5-0.8 s instead of 0.8-1.5 s). Grow-only, so a no-op after the first run.
$FS vm resize "$SLUG" --cpu 8 --memory 16384 >/dev/null 2>&1 || true

echo "pulling $IMAGE (a few GB, first time only)"
$FS vm exec "$SLUG" --linux-user root --timeout-ms 900000 -- docker pull "$IMAGE"
$FS vm exec "$SLUG" --linux-user root -- sh -c "docker rm -f kokoro >/dev/null 2>&1 || true"
$FS vm exec "$SLUG" --linux-user root -- docker run -d --name kokoro --restart unless-stopped \
  -p "$PORT:$PORT" "$IMAGE"

echo "waiting for the model to load"
for i in $(seq 1 90); do
  CODE=$($FS vm exec "$SLUG" --linux-user root -- python3 -c "import urllib.request,sys
try: print(urllib.request.urlopen('http://localhost:$PORT/v1/audio/voices',timeout=5).status)
except Exception as e: print(getattr(e,'code',0))" | tr -d '\r\n')
  [ "$CODE" = "200" ] && break
  sleep 2
done
echo "kokoro answers locally with HTTP $CODE"

if ! $FS --output json tls list --vm "$SLUG" 2>/dev/null | grep -q "\"$DOMAIN\""; then
  $FS tls create --domain "$DOMAIN" --from public --to "vm=$SLUG,port=$PORT" >/dev/null
fi

echo
echo "voice:  https://$DOMAIN"
echo "try:    curl -s https://$DOMAIN/v1/audio/speech -H 'Content-Type: application/json' \\"
echo "          -d '{\"model\":\"kokoro\",\"input\":\"Start. Move right.\",\"voice\":\"af_heart\",\"response_format\":\"wav\"}' -o out.wav && afplay out.wav"
echo "app:    SpatialAudioEngine(speech: KokoroSpeechProvider(baseURL: URL(string: \"https://$DOMAIN\")!))"
echo "Snapshot it once it works, so the loaded model comes back instantly:"
echo "        npx -y freestyle@latest snapshot create $SLUG --slug $SLUG-ok"
