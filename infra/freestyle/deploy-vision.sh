#!/usr/bin/env bash
# Runs an open-weight vision-language model behind llama.cpp's OpenAI-compatible
# server on a Freestyle VM, published at https://<SLUG>.style.dev. The app's
# cloud router talks to it as an OpenAI provider (chat completions + image_url),
# no API key. This is what gives Explore and Describe scene understanding:
# what kind of place, what is happening, colours and shapes, not just labels.
#
#   infra/freestyle/deploy-vision.sh
#   MODEL=ggml-org/SmolVLM-500M-Instruct-GGUF infra/freestyle/deploy-vision.sh   # faster, weaker
set -euo pipefail

SLUG="${SLUG:-echoguide-vision}"
DOMAIN="${DOMAIN:-$SLUG.style.dev}"
PORT=8080
MODEL="${MODEL:-ggml-org/SmolVLM2-2.2B-Instruct-GGUF}"
IMAGE="${IMAGE:-ghcr.io/ggml-org/llama.cpp:server}"
FS="npx -y freestyle@latest"

if ! $FS --output json vm get "$SLUG" >/dev/null 2>&1; then
  echo "creating VM $SLUG"
  $FS vm create --slug "$SLUG" --snapshot-id freestyle/ubuntu --no-ssh \
    --display-name "EchoGuide vision model" --metadata app=echoguide --metadata role=vision >/dev/null
fi
$FS vm start "$SLUG" >/dev/null 2>&1 || true
# Vision encoders are CPU-hungry: 8 vCPU. Grow-only, no-op after the first run.
$FS vm resize "$SLUG" --cpu 8 --memory 16384 >/dev/null 2>&1 || true

echo "pulling $IMAGE"
$FS vm exec "$SLUG" --linux-user root --timeout-ms 900000 -- docker pull "$IMAGE" >/dev/null
$FS vm exec "$SLUG" --linux-user root -- sh -c "docker rm -f vlm >/dev/null 2>&1 || true; mkdir -p /srv/llama-cache"
# The model is downloaded from Hugging Face on first start and cached on the VM disk.
# One quoted shell string: the Freestyle CLI mis-parses bare numeric flags after "--".
$FS vm exec "$SLUG" --linux-user root -- sh -c "docker run -d --name vlm --restart unless-stopped \
  -p $PORT:$PORT -v /srv/llama-cache:/root/.cache/llama.cpp $IMAGE \
  -hf $MODEL --host 0.0.0.0 --port $PORT -c 4096 -t 8 -np 2 --no-warmup"

echo "waiting for the model to download and load (first time: a few minutes)"
for i in $(seq 1 150); do
  # Single-line probe: the CLI mangles multi-line arguments.
  CODE=$($FS vm exec "$SLUG" --linux-user root -- python3 -c "import urllib.request as u; print(u.urlopen('http://localhost:$PORT/health',timeout=5).status)" 2>/dev/null | tr -d '\r\n')
  [ "$CODE" = "200" ] && break
  sleep 4
done
echo "vision server answers locally with HTTP ${CODE:-000}"

if ! $FS --output json tls list --vm "$SLUG" 2>/dev/null | grep -q "\"$DOMAIN\""; then
  $FS tls create --domain "$DOMAIN" --from public --to "vm=$SLUG,port=$PORT" >/dev/null
fi
echo
echo "vision:  https://$DOMAIN   (OpenAI-compatible: POST /v1/chat/completions)"
echo "app:     \"visionURL\": \"https://$DOMAIN\" in echoguide.json"
echo "Snapshot once it works:  npx -y freestyle@latest snapshot create $SLUG --slug $SLUG-ok"
