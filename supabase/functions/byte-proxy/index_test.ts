// BYTE_PROXY_NO_SERVE=1 deno test -A supabase/functions/byte-proxy/index_test.ts
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { BOT_BLOCKED, checkTarget, handle, hostAllowed, isBotPage, parseRange, pickFormat, RateLimiter, upstreamHeaders } from './index.ts';

Deno.test('allowlist', () => {
  assert(hostAllowed('music.youtube.com'));
  assert(hostAllowed('rr3---sn-abc.googlevideo.com'));
  assert(hostAllowed('i.ytimg.com'));
  assert(hostAllowed('lh3.googleusercontent.com'));
  assert(!hostAllowed('googlevideo.com.evil.com'));
  assert(!hostAllowed('evilgooglevideo.com'));
  assert(!hostAllowed('storage.googleusercontent.com'));
  assert(!hostAllowed('example.com'));
  assert('error' in checkTarget('http://music.youtube.com/'));
  assert('error' in checkTarget('https://music.youtube.com:8443/'));
  assert('error' in checkTarget('https://user:pw@music.youtube.com/'));
  assert('url' in checkTarget('http://mobilecdn.kugou.com/api/v3/search'));
  assert('url' in checkTarget('https://lrclib.net/api/get?x=1'));
});

Deno.test('headers: app headers pass, cookies never', () => {
  const r = new Request('http://x/?u=1', {
    headers: { 'x-byte-h': JSON.stringify({ 'User-Agent': 'UA1', Cookie: 'a=b', 'X-Goog-Visitor-Id': 'v' }), range: 'bytes=0-9', cookie: 'c=d' },
  });
  const h = upstreamHeaders(r);
  assertEquals(h.get('user-agent'), 'UA1');
  assertEquals(h.get('x-goog-visitor-id'), 'v');
  assertEquals(h.get('range'), 'bytes=0-9');
  assertEquals(h.get('cookie'), null);
});

Deno.test('range parsing', () => {
  assertEquals(parseRange('bytes=0-', 100), { start: 0, end: 99 });
  assertEquals(parseRange('bytes=10-19', 100), { start: 10, end: 19 });
  assertEquals(parseRange('bytes=-10', 100), { start: 90, end: 99 });
  assertEquals(parseRange('bytes=90-500', 100), { start: 90, end: 99 });
  assertEquals(parseRange('bytes=200-', 100), null);
  assertEquals(parseRange(null, 100), null);
});

Deno.test('format pick', () => {
  const p = { streamingData: { adaptiveFormats: [
    { url: 'a', mimeType: 'audio/webm; codecs="opus"', bitrate: 160000, contentLength: '10' },
    { url: 'b', mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 130000, contentLength: '20' },
    { url: 'c', mimeType: 'audio/mp4; codecs="mp4a.40.5"', bitrate: 48000, contentLength: '30' },
    { url: 'v', mimeType: 'video/mp4', bitrate: 900000 },
  ] } };
  assertEquals(pickFormat(p, 'high', false)?.url, 'a');
  assertEquals(pickFormat(p, 'high', true)?.url, 'b');
  assertEquals(pickFormat(p, 'low', true)?.url, 'c');
});

Deno.test('rate limit', () => {
  const l = new RateLimiter(3, 1000);
  assert(l.allow('1', 0) && l.allow('1', 1) && l.allow('1', 2));
  assert(!l.allow('1', 3));
  assert(l.allow('2', 3));
  assert(l.allow('1', 1001));
});

Deno.test('refuses hosts off the list', async () => {
  const r = await handle(new Request('http://x/?u=' + encodeURIComponent('https://evil.example/'), { headers: { origin: 'https://byte-apurba.sites.tab.bot' } }));
  assertEquals(r.status, 403);
  assertEquals(r.headers.get('x-byte-proxy'), 'refused');
  assertEquals(r.headers.get('access-control-allow-origin'), 'https://byte-apurba.sites.tab.bot');
  await r.body?.cancel();
});

// A fake catalogue + audio server: proves resolve-and-stream in one call,
// ranges, and piecewise fetching (not that YouTube accepts a given server).
Deno.test('play: resolves, streams in pieces, honours Range', async () => {
  const SIZE = 9 * 1024 * 1024 + 123; // > 2 pieces
  const audio = new Uint8Array(SIZE);
  for (let i = 0; i < SIZE; i++) audio[i] = i % 251;
  const real = globalThis.fetch;
  const seen: string[] = [];
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const u = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (u.pathname === '/sw.js_data') return new Response('xx "CgtFAKEVISITOR1234" yy');
    if (u.pathname.endsWith('/player')) {
      const body = JSON.parse(String(init?.body));
      const ok = body.context.client.clientName === 'ANDROID_VR';
      return Response.json({
        playabilityStatus: { status: 'OK' },
        streamingData: { adaptiveFormats: [{ url: `https://rr1---sn-x.googlevideo.com/videoplayback?c=${body.context.client.clientName}&ok=${ok}`, mimeType: 'audio/webm; codecs="opus"', bitrate: 1, contentLength: String(SIZE) }] },
      });
    }
    if (u.hostname.endsWith('.googlevideo.com')) {
      seen.push(u.searchParams.get('range') ?? 'none');
      if (u.searchParams.get('ok') !== 'true') return new Response('', { status: 403 });
      const [a, b] = (u.searchParams.get('range') ?? `0-${SIZE - 1}`).split('-').map(Number);
      return new Response(audio.slice(a, b + 1), { status: 200 });
    }
    return new Response('?', { status: 404 });
  }) as typeof fetch;
  try {
    const r = await handle(new Request('http://x/?play=abcdefghijk', { headers: { range: 'bytes=100-' } }));
    assertEquals(r.status, 206);
    assertEquals(r.headers.get('content-range'), `bytes 100-${SIZE - 1}/${SIZE}`);
    assertEquals(r.headers.get('x-byte-proxy'), 'play;ANDROID_VR');
    const got = new Uint8Array(await r.arrayBuffer());
    assertEquals(got.length, SIZE - 100);
    assertEquals(got[0], 100 % 251);
    assertEquals(got[got.length - 1], (SIZE - 1) % 251);
    assert(seen.filter((x) => x !== '0-1').length >= 3, 'fetched in pieces: ' + seen.join(','));
    const r2 = await handle(new Request('http://x/?play=abcdefghijk', { headers: { range: 'bytes=0-9' } }));
    assertEquals([...new Uint8Array(await r2.arrayBuffer())], [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    const bad = await handle(new Request('http://x/?play=../../etc'));
    assertEquals(bad.status, 400);
    await bad.body?.cancel();
  } finally {
    globalThis.fetch = real;
  }
});

// Through a real Deno HTTP server: content-length + piecewise streaming + Range.
Deno.test('play over HTTP: a browser-style Range read gets the exact bytes', async () => {
  const SIZE = 5 * 1024 * 1024 + 7;
  const audio = new Uint8Array(SIZE).map((_, i) => i % 253);
  const real = globalThis.fetch;
  globalThis.fetch = (async (input: Request | URL | string, init?: RequestInit) => {
    const u = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url);
    if (u.hostname === '127.0.0.1') return real(input, init);
    if (u.pathname === '/sw.js_data') return new Response('');
    if (u.pathname.endsWith('/player')) {
      return Response.json({ playabilityStatus: { status: 'OK' }, streamingData: { adaptiveFormats: [{ url: 'https://rr2---sn-y.googlevideo.com/videoplayback?x=1', mimeType: 'audio/mp4; codecs="mp4a.40.2"', bitrate: 1, contentLength: String(SIZE) }] } });
    }
    const [a, b] = (u.searchParams.get('range') ?? '0-0').split('-').map(Number);
    return new Response(audio.slice(a, b + 1));
  }) as typeof fetch;
  const ac = new AbortController();
  const srv = Deno.serve({ port: 0, signal: ac.signal, onListen() {} }, handle);
  try {
    const port = (srv.addr as Deno.NetAddr).port;
    const r = await real(`http://127.0.0.1:${port}/?play=ZZZZZZZZZZZ&f=mp4`, { headers: { range: 'bytes=4194300-' } });
    assertEquals(r.status, 206);
    assertEquals(r.headers.get('content-type'), 'audio/mp4');
    assertEquals(Number(r.headers.get('content-length')), SIZE - 4194300);
    const got = new Uint8Array(await r.arrayBuffer());
    assertEquals(got.length, SIZE - 4194300);
    assertEquals(got[0], 4194300 % 253);
    assertEquals(got[got.length - 1], (SIZE - 1) % 253);
  } finally {
    globalThis.fetch = real;
    ac.abort();
    await srv.finished;
  }
});

// 1.4.6: the catalogue answers the Supabase server's address with a "Sorry…"
// robot-check page for /player (every client, every host); search still works.
const SORRY = '<html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"/><title>Sorry...</title></head><body>unusual traffic</body></html>';

Deno.test('robot-check page is recognised; JSON answers are not', () => {
  assert(isBotPage(403, 'text/html; charset=utf-8', SORRY));
  assert(isBotPage(429, null, '<html>x</html>'));
  assert(isBotPage(200, 'text/html', SORRY));
  assert(!isBotPage(200, 'application/json', '{"playabilityStatus":{"status":"OK"}}'));
  assert(!isBotPage(403, 'application/json', '{"error":{"code":403}}'));
});

Deno.test('?play answers 503 "blocked: bot check" (not a JSON parse error) when the catalogue shows its robot page', async () => {
  const real = globalThis.fetch;
  let playerCalls = 0;
  globalThis.fetch = ((input: Request | URL | string) => {
    const u = String(input instanceof Request ? input.url : input);
    if (u.includes('/youtubei/v1/player')) playerCalls++;
    if (u.includes('sw.js_data')) return Promise.resolve(new Response(')]}\'\n[]', { status: 200 }));
    return Promise.resolve(new Response(SORRY, { status: 403, headers: { 'content-type': 'text/html; charset=utf-8' } }));
  }) as typeof fetch;
  try {
    const r = await handle(new Request('http://x/?play=dQw4w9WgXcQ', { headers: { 'x-forwarded-for': '10.9.9.9' } }));
    assertEquals(r.status, 503);
    const j = await r.json();
    assertEquals(j.error, BOT_BLOCKED);
    assert(String(j.error).includes('bot check'));
    assertEquals(playerCalls, 1, 'stops after the first robot page instead of trying every client');
  } finally {
    globalThis.fetch = real;
  }
});
