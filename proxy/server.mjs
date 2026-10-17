// Owner: Maxwell. The only place the Gemini, OpenAI, Deepgram and ElevenLabs
// keys live. Devices authenticate with a per-device bearer token; the proxy
// checks it against SHA-256 hashes (so a leaked env file does not leak device
// tokens), rate-limits per device, allow-lists models, clamps output length
// and caps body size, then forwards to the provider.
//
// Env:
//   PORT                       default 8787
//   DEVICE_TOKEN_SHA256S       comma-separated hex sha256 of allowed device tokens
//   GEMINI_API_KEY, OPENAI_API_KEY, DEEPGRAM_API_KEY, ELEVENLABS_API_KEY
//   ALLOWED_MODELS             default "gemini-2.5-flash,gpt-4o"
//   RATE_PER_MINUTE            default 30 requests per device per minute
//   *_BASE                     upstream overrides (tests)

import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';

export function createProxy(env = process.env) {
  const tokenHashes = (env.DEVICE_TOKEN_SHA256S ?? '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
    .map(h => Buffer.from(h, 'hex'));
  const allowedModels = new Set((env.ALLOWED_MODELS ?? 'gemini-2.5-flash,gpt-4o').split(',').map(s => s.trim()));
  const ratePerMinute = Number(env.RATE_PER_MINUTE ?? 30);
  const maxBody = 2 * 1024 * 1024; // one low-detail JPEG plus prompt
  const base = {
    gemini: env.GEMINI_BASE ?? 'https://generativelanguage.googleapis.com',
    openai: env.OPENAI_BASE ?? 'https://api.openai.com',
    deepgram: env.DEEPGRAM_BASE ?? 'https://api.deepgram.com',
    eleven: env.ELEVENLABS_BASE ?? 'https://api.elevenlabs.io',
  };
  const buckets = new Map(); // device hash -> { tokens, at }

  function authorize(req) {
    const m = /^Bearer (.+)$/.exec(req.headers.authorization ?? '');
    if (!m) return null;
    const digest = createHash('sha256').update(m[1]).digest();
    return tokenHashes.some(h => h.length === digest.length && timingSafeEqual(h, digest)) ? digest.toString('hex') : null;
  }

  function allow(device) {
    const now = Date.now();
    const b = buckets.get(device) ?? { tokens: ratePerMinute, at: now };
    b.tokens = Math.min(ratePerMinute, b.tokens + ((now - b.at) / 60000) * ratePerMinute);
    b.at = now;
    if (b.tokens < 1) { buckets.set(device, b); return false; }
    b.tokens -= 1;
    buckets.set(device, b);
    return true;
  }

  async function readJSON(req) {
    let size = 0;
    const chunks = [];
    for await (const c of req) {
      size += c.length;
      if (size > maxBody) throw Object.assign(new Error('body too large'), { status: 413 });
      chunks.push(c);
    }
    try { return chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {}; }
    catch { throw Object.assign(new Error('invalid json'), { status: 400 }); }
  }

  function send(res, status, obj) {
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(obj));
  }

  async function forward(res, url, init) {
    const upstream = await fetch(url, { ...init, signal: AbortSignal.timeout(10000) });
    const headers = { 'content-type': upstream.headers.get('content-type') ?? 'application/octet-stream' };
    res.writeHead(upstream.status, headers);
    if (!upstream.body) return res.end();
    for await (const chunk of upstream.body) res.write(chunk); // streams TTS audio as it arrives
    res.end();
  }

  const clamp = (n, max) => Math.min(Number.isFinite(n) ? n : max, max);

  return createServer(async (req, res) => {
    try {
      const url = new URL(req.url, 'http://proxy');
      if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true });
      if (req.method !== 'POST') return send(res, 405, { error: 'method not allowed' });

      const device = authorize(req);
      if (!device) return send(res, 401, { error: 'unauthorized' });
      if (!allow(device)) return send(res, 429, { error: 'rate limited' });

      const gemini = /^\/v1beta\/models\/([\w.-]+):generateContent$/.exec(url.pathname);
      if (gemini) {
        if (!allowedModels.has(gemini[1])) return send(res, 400, { error: 'model not allowed' });
        const body = await readJSON(req);
        body.generationConfig = { ...(body.generationConfig ?? {}), maxOutputTokens: clamp(body.generationConfig?.maxOutputTokens, 120) };
        return forward(res, `${base.gemini}/v1beta/models/${gemini[1]}:generateContent`, {
          method: 'POST', headers: { 'content-type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY ?? '' },
          body: JSON.stringify({ contents: body.contents, generationConfig: body.generationConfig }),
        });
      }

      if (url.pathname === '/v1/chat/completions') {
        const body = await readJSON(req);
        if (!allowedModels.has(body.model)) return send(res, 400, { error: 'model not allowed' });
        return forward(res, `${base.openai}/v1/chat/completions`, {
          method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${env.OPENAI_API_KEY ?? ''}` },
          body: JSON.stringify({ model: body.model, messages: body.messages, max_tokens: clamp(body.max_tokens, 120), temperature: body.temperature ?? 0.2 }),
        });
      }

      if (url.pathname === '/v1/voice/stt-token') {
        // Short-lived Deepgram token: the device opens the WebSocket directly,
        // the long-lived key never leaves this server.
        return forward(res, `${base.deepgram}/v1/auth/grant`, {
          method: 'POST', headers: { 'content-type': 'application/json', authorization: `Token ${env.DEEPGRAM_API_KEY ?? ''}` },
          body: JSON.stringify({ ttl_seconds: 30 }),
        });
      }

      if (url.pathname === '/v1/voice/tts') {
        const body = await readJSON(req);
        const text = String(body.text ?? '').slice(0, 400);
        const voice = String(body.voice_id ?? '');
        if (!text || !/^[A-Za-z0-9]+$/.test(voice)) return send(res, 400, { error: 'text and voice_id required' });
        return forward(res, `${base.eleven}/v1/text-to-speech/${voice}/stream?output_format=pcm_16000`, {
          method: 'POST', headers: { 'content-type': 'application/json', 'xi-api-key': env.ELEVENLABS_API_KEY ?? '' },
          body: JSON.stringify({ text, model_id: 'eleven_flash_v2_5' }),
        });
      }

      return send(res, 404, { error: 'not found' });
    } catch (err) {
      if (!res.headersSent) send(res, err.status ?? 502, { error: err.status ? err.message : 'upstream error' });
      else res.end();
    }
  });
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.PORT ?? 8787);
  createProxy().listen(port, () => console.log(`echoguide proxy on :${port}`));
}
