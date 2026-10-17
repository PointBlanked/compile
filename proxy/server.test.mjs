import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { createProxy } from './server.mjs';

const TOKEN = 'device-secret';
let upstream, proxy, proxyURL, seen = [];

before(async () => {
  upstream = createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    seen.push({ url: req.url, headers: req.headers, body: body ? JSON.parse(body) : null });
    if (req.url.startsWith('/v1/text-to-speech/')) {
      res.writeHead(200, { 'content-type': 'audio/pcm' });
      res.write(Buffer.alloc(3200)); res.end(Buffer.alloc(800));
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(req.url === '/v1/auth/grant' ? { access_token: 'jwt', expires_in: 30 } : { ok: true }));
  });
  await new Promise(r => upstream.listen(0, r));
  const u = `http://127.0.0.1:${upstream.address().port}`;
  proxy = createProxy({
    DEVICE_TOKEN_SHA256S: createHash('sha256').update(TOKEN).digest('hex'),
    GEMINI_API_KEY: 'gk', OPENAI_API_KEY: 'ok', DEEPGRAM_API_KEY: 'dk', ELEVENLABS_API_KEY: 'ek',
    GEMINI_BASE: u, OPENAI_BASE: u, DEEPGRAM_BASE: u, ELEVENLABS_BASE: u, RATE_PER_MINUTE: '12',
  });
  await new Promise(r => proxy.listen(0, r));
  proxyURL = `http://127.0.0.1:${proxy.address().port}`;
});

after(() => { upstream.close(); proxy.close(); });

const post = (path, body, token = TOKEN) => fetch(proxyURL + path, {
  method: 'POST', headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
  body: JSON.stringify(body),
});

test('rejects missing or wrong device token', async () => {
  assert.equal((await post('/v1/chat/completions', {}, null)).status, 401);
  assert.equal((await post('/v1/chat/completions', {}, 'nope')).status, 401);
});

test('gemini: adds key, clamps tokens, drops extra fields', async () => {
  seen = [];
  const r = await post('/v1beta/models/gemini-2.5-flash:generateContent', { contents: [{ parts: [{ text: 'hi' }] }], generationConfig: { maxOutputTokens: 9999 }, tools: ['x'] });
  assert.equal(r.status, 200);
  assert.equal(seen[0].headers['x-goog-api-key'], 'gk');
  assert.equal(seen[0].body.generationConfig.maxOutputTokens, 120);
  assert.equal(seen[0].body.tools, undefined);
});

test('model allow-list', async () => {
  assert.equal((await post('/v1beta/models/gemini-ultra:generateContent', {})).status, 400);
  assert.equal((await post('/v1/chat/completions', { model: 'o3-pro', messages: [] })).status, 400);
});

test('deepgram grant returns a short-lived token', async () => {
  seen = [];
  const r = await post('/v1/voice/stt-token', {});
  assert.deepEqual(await r.json(), { access_token: 'jwt', expires_in: 30 });
  assert.equal(seen[0].headers.authorization, 'Token dk');
  assert.equal(seen[0].body.ttl_seconds, 30);
});

test('tts streams audio bytes through', async () => {
  const r = await post('/v1/voice/tts', { text: 'Microwave started.', voice_id: 'abc123' });
  assert.equal(r.status, 200);
  assert.equal((await r.arrayBuffer()).byteLength, 4000);
  assert.equal((await post('/v1/voice/tts', { text: 'x', voice_id: '../admin' })).status, 400);
});

test('rate limits per device', async () => {
  let last;
  for (let i = 0; i < 20; i++) last = await post('/v1/chat/completions', { model: 'gpt-4o', messages: [] });
  assert.equal(last.status, 429);
});
