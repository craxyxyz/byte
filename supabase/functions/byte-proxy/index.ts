// Byte web server: lets the Byte web app (a browser page) reach the music
// catalogue, lyrics and import sites, which don't allow calls from web pages
// (CORS), and plays songs for it.
//
// © 2026 Apurba Laskar. Runs on Supabase Edge Functions (Deno) and, unchanged,
// on any Deno host (Deno.serve).
//
//   GET  ?ping=1                      -> {"ok":true,"name":"byte-proxy","v":1}
//   ANY  ?u=<encoded https url>       -> forwards to an ALLOWED host only.
//        header  x-byte-h: {"User-Agent":"…", …}  (the request's own headers as
//        JSON, since a browser may not set User-Agent/Origin/Referer itself)
//        body    passed through (POST/PUT/PATCH)
//   GET  ?play=<videoId>[&q=high|low][&f=mp4]
//        finds the song's audio stream AND streams it in the same call, so
//        the IP that asked for the stream is the IP that fetches it (YouTube
//        stream links only work from the IP that asked). Range requests work
//        (seeking). <audio src="…?play=ID"> needs no headers.
//
// Deploy with JWT checking OFF (an <audio> tag can't send an auth header):
//   supabase functions deploy byte-proxy --no-verify-jwt
// Safety: allowlisted hosts only, https only, cookies stripped both ways,
// per-IP rate limit, no logging of bodies.

const VERSION = 1;

/** Hosts Byte's own code calls. Anything else is refused. */
export const ALLOWED_HOSTS = [
  'music.youtube.com',
  'www.youtube.com',
  'youtube.com',
  'm.youtube.com',
  'youtubei.googleapis.com',
  'suggestqueries.google.com',
  'inputtools.google.com',
  'clients5.google.com',
  'translate.googleapis.com',
  'lrclib.net',
  'lyrics.kugou.com',
  'krcs.kugou.com',
  'songsearch.kugou.com',
  'mobilecdn.kugou.com',
  'api.musixmatch.com',
  'apic-desktop.musixmatch.com',
  'api.mymemory.translated.net',
  'api.deezer.com',
  'www.deezer.com',
  'deezer.page.link',
  'link.deezer.com',
  'www.jiosaavn.com',
  'jiosaavn.com',
  'gaana.com',
  'api-v2.soundcloud.com',
  'soundcloud.com',
  'on.soundcloud.com',
  'music.apple.com',
  'music.amazon.com',
  'music.amazon.in',
  'open.spotify.com',
  'spotify.link',
  'api.spotify.com',
  'api-partner.spotify.com',
  'spclient.wg.spotify.com',
  'accounts.spotify.com',
  'ws.audioscrobbler.com',
  'www.last.fm',
  'api.listenbrainz.org',
  'listenbrainz.org',
];
/** Suffixes: any sub-host of these (audio servers and cover images). */
export const ALLOWED_SUFFIXES = ['.googlevideo.com', '.ytimg.com', '.ggpht.com', '.scdn.co', '.spotifycdn.com'];
/** Cover-image hosts on googleusercontent (not the whole domain). */
const GUC = /^lh[3-6]\.googleusercontent\.com$/;
/** The one host Byte's code reaches over plain http. */
export const HTTP_OK = ['mobilecdn.kugou.com'];

export function hostAllowed(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, '');
  if (ALLOWED_HOSTS.includes(h) || GUC.test(h)) return true;
  return ALLOWED_SUFFIXES.some((s) => h.endsWith(s) && h.length > s.length);
}

/** The target URL if it is https and on the allowlist, else a reason. */
export function checkTarget(raw: string | null): { url: URL } | { error: string } {
  if (!raw) return { error: 'missing u' };
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { error: 'bad url' };
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && HTTP_OK.includes(url.hostname))) return { error: 'https only' };
  if (url.username || url.password) return { error: 'no credentials in url' };
  if (url.port) return { error: 'port not allowed' };
  if (!hostAllowed(url.hostname)) return { error: `host not allowed: ${url.hostname}` };
  return { url };
}

const DROP_REQUEST = new Set(['cookie', 'host', 'content-length', 'connection', 'transfer-encoding', 'x-forwarded-for', 'x-real-ip', 'forwarded', 'proxy-authorization', 'te', 'upgrade', 'keep-alive']);

/** Headers sent upstream: the app's own (x-byte-h) plus Range/Content-Type; never cookies. */
export function upstreamHeaders(req: Request): Headers {
  const out = new Headers();
  const raw = req.headers.get('x-byte-h');
  if (raw) {
    try {
      const obj = JSON.parse(raw);
      if (obj && typeof obj === 'object') {
        for (const [k, v] of Object.entries(obj)) {
          if (typeof v !== 'string') continue;
          if (DROP_REQUEST.has(k.toLowerCase())) continue;
          out.set(k, v);
        }
      }
    } catch { /* ignore bad header json */ }
  }
  for (const k of ['range', 'content-type', 'if-range']) {
    const v = req.headers.get(k);
    if (v && !out.has(k)) out.set(k, v);
  }
  if (!out.has('user-agent')) out.set('user-agent', 'Byte/1.0 (music player by Apurba Laskar)');
  return out;
}

export function corsHeaders(origin: string | null): Headers {
  const h = new Headers();
  h.set('access-control-allow-origin', origin ?? '*');
  h.set('vary', 'origin');
  h.set('access-control-allow-methods', 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS');
  h.set('access-control-allow-headers', 'x-byte-h, content-type, range, if-range, authorization, apikey, x-client-info');
  h.set('access-control-expose-headers', '*, content-range, content-length, accept-ranges, x-byte-proxy, x-byte-final-url');
  h.set('access-control-max-age', '86400');
  return h;
}

const PASS_RESPONSE = ['content-type', 'content-length', 'content-range', 'accept-ranges', 'cache-control', 'etag', 'last-modified', 'expires', 'location', 'content-language', 'date'];

function respondUpstream(up: Response, origin: string | null, extra: Record<string, string> = {}): Response {
  const h = corsHeaders(origin);
  for (const k of PASS_RESPONSE) {
    const v = up.headers.get(k);
    if (v) h.set(k, v);
  }
  for (const [k, v] of Object.entries(extra)) h.set(k, v);
  // never set-cookie; body stays compressed-free (fetch already decoded it)
  if (up.headers.get('content-encoding')) h.delete('content-length');
  return new Response(up.body, { status: up.status, statusText: up.statusText, headers: h });
}

function refuse(status: number, reason: string, origin: string | null): Response {
  const h = corsHeaders(origin);
  h.set('content-type', 'application/json');
  h.set('x-byte-proxy', 'refused');
  return new Response(JSON.stringify({ error: reason, proxy: 'byte-proxy' }), { status, headers: h });
}

// ---------- per-IP rate limit (per running copy of the function) ----------
export class RateLimiter {
  private hits = new Map<string, { n: number; start: number }>();
  constructor(public limit = 300, public windowMs = 60_000) {}
  allow(ip: string, now = Date.now()): boolean {
    const e = this.hits.get(ip);
    if (!e || now - e.start >= this.windowMs) {
      this.hits.set(ip, { n: 1, start: now });
      if (this.hits.size > 5000) this.prune(now);
      return true;
    }
    e.n++;
    return e.n <= this.limit;
  }
  private prune(now: number) {
    for (const [k, v] of this.hits) if (now - v.start >= this.windowMs) this.hits.delete(k);
  }
}
const limiter = new RateLimiter(Number(Deno.env.get('BYTE_PROXY_RPM') ?? 300));
export function clientIp(req: Request): string {
  const xf = req.headers.get('x-forwarded-for');
  if (xf) return xf.split(',')[0].trim();
  return req.headers.get('x-real-ip') ?? req.headers.get('cf-connecting-ip') ?? 'unknown';
}

// ---------- play: resolve + stream in one place ----------
type Client = { name: string; version: string; ua: string; extra: Record<string, unknown> };
export const CLIENTS: Client[] = [
  {
    name: 'VISIONOS', version: '1.02',
    ua: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    extra: { deviceMake: 'Apple', deviceModel: 'RealityDevice17,1', osName: 'visionOS', osVersion: '26.5.23O471' },
  },
  {
    name: 'ANDROID_VR', version: '1.65.10',
    ua: 'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    extra: { deviceMake: 'Oculus', deviceModel: 'Quest 3', androidSdkVersion: 32, osName: 'Android', osVersion: '12L' },
  },
  {
    name: 'IOS', version: '20.10.4',
    ua: 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    extra: { deviceMake: 'Apple', deviceModel: 'iPhone16,2', osName: 'iPhone', osVersion: '18.3.2.22D82' },
  },
];

type Stream = { url: string; ua: string; mime: string; length: number; client: string; at: number };
const streamCache = new Map<string, Stream>();
const STREAM_TTL_MS = 60 * 60 * 1000;
let visitorData: string | null = null;

async function getVisitorData(): Promise<string | null> {
  if (visitorData) return visitorData;
  try {
    const r = await fetch('https://music.youtube.com/sw.js_data', { headers: { 'user-agent': CLIENTS[0].ua } });
    const t = await r.text();
    const m = /"(Cg[A-Za-z0-9_\-%]{10,})"/.exec(t);
    visitorData = m ? decodeURIComponent(m[1]) : null;
  } catch { /* fine without */ }
  return visitorData;
}

// deno-lint-ignore no-explicit-any
export function pickFormat(player: any, q: string, mp4: boolean): { url: string; mime: string; length: number } | null {
  const fmts: any[] = (player?.streamingData?.adaptiveFormats ?? []).filter(
    (f: any) => typeof f?.url === 'string' && typeof f?.mimeType === 'string' && f.mimeType.startsWith('audio/'),
  );
  let pool = mp4 ? fmts.filter((f) => f.mimeType.startsWith('audio/mp4')) : fmts;
  if (!pool.length) pool = fmts;
  if (!pool.length) return null;
  pool.sort((a, b) => (a.bitrate ?? 0) - (b.bitrate ?? 0));
  const f = q === 'low' ? pool[0] : pool[pool.length - 1];
  return { url: f.url, mime: String(f.mimeType).split(';')[0], length: Number(f.contentLength ?? 0) };
}

/** What ?play answers when the catalogue's robot check blocks this server. */
export const BOT_BLOCKED = 'blocked: bot check. The music service is blocking this server\'s address, so songs cannot be fetched from here';

/** The catalogue's "Sorry…" / robot-check page instead of a JSON answer. */
export function isBotPage(status: number, contentType: string | null, text: string): boolean {
  const html = (contentType ?? '').includes('text/html') || text.trimStart().startsWith('<');
  if (!html) return false;
  return status === 403 || status === 429 || /<title>\s*Sorry/i.test(text) || /unusual traffic|not a robot|captcha/i.test(text);
}

export class PlayError extends Error {
  constructor(msg: string, public status = 502) {
    super(msg);
  }
}

async function resolveStream(videoId: string, q: string, mp4: boolean, fresh = false): Promise<Stream> {
  const key = `${videoId}|${q}|${mp4}`;
  const hit = streamCache.get(key);
  if (!fresh && hit && Date.now() - hit.at < STREAM_TTL_MS) return hit;
  const vd = await getVisitorData();
  let reason = 'This song cannot be played';
  for (const c of CLIENTS) {
    try {
      const body = {
        context: { client: { clientName: c.name, clientVersion: c.version, hl: 'en', gl: 'IN', ...(vd ? { visitorData: vd } : {}), ...c.extra }, user: { lockedSafetyMode: false } },
        videoId, contentCheckOk: true, racyCheckOk: true,
        playbackContext: { contentPlaybackContext: { html5Preference: 'HTML5_PREF_WANTS' } },
      };
      const r = await fetch('https://www.youtube.com/youtubei/v1/player?prettyPrint=false', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'user-agent': c.ua, ...(vd ? { 'x-goog-visitor-id': vd } : {}), origin: 'https://www.youtube.com' },
        body: JSON.stringify(body),
      });
      const text = await r.text();
      if (isBotPage(r.status, r.headers.get('content-type'), text)) {
        // The catalogue answers this server's address with its "Sorry…" robot
        // check page (seen 2026-11-03 for every client and host). Every client
        // gets the same page, so stop and say so plainly.
        throw new PlayError(BOT_BLOCKED, 503);
      }
      const j = JSON.parse(text);
      const status = j?.playabilityStatus?.status;
      if (status === 'OK') {
        const f = pickFormat(j, q, mp4);
        if (f) {
          const s: Stream = { ...f, ua: c.ua, client: c.name, at: Date.now() };
          if (!(await probe(s))) {
            // the audio server refuses this server's address for this client
            reason = 'stream_blocked: the audio server refused this server (403)';
            continue;
          }
          streamCache.set(key, s);
          if (streamCache.size > 500) streamCache.delete(streamCache.keys().next().value!);
          return s;
        }
      }
      reason = j?.playabilityStatus?.reason ?? status ?? `HTTP ${r.status}`;
    } catch (e) {
      if (e instanceof PlayError) throw e;
      reason = String(e);
    }
  }
  throw new PlayError(reason, reason.startsWith('stream_blocked') ? 503 : 502);
}

const CHUNK = 4 * 1024 * 1024; // YouTube serves bounded pieces fastest

export function parseRange(h: string | null, length: number): { start: number; end: number } | null {
  if (!h) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(h.trim());
  if (!m) return null;
  let start: number, end: number;
  if (m[1] === '' && m[2] !== '') {
    const n = Number(m[2]);
    start = Math.max(0, length - n);
    end = length - 1;
  } else {
    start = Number(m[1] || 0);
    end = m[2] === '' ? length - 1 : Math.min(Number(m[2]), length - 1);
  }
  if (!(start >= 0) || start > end || (length > 0 && start >= length)) return null;
  return { start, end };
}

/** Streams [start, end] from the stream URL in bounded pieces, as one body. */
function pieces(s: Stream, start: number, end: number): ReadableStream<Uint8Array> {
  // own abort (Deno aborts request.signal once a response is returned)
  const ac = new AbortController();
  const signal = ac.signal;
  let pos = start;
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  return new ReadableStream<Uint8Array>({
    async pull(ctl) {
      while (true) {
        if (!reader) {
          if (pos > end) {
            ctl.close();
            return;
          }
          const to = Math.min(end, pos + CHUNK - 1);
          const u = new URL(s.url);
          u.searchParams.set('range', `${pos}-${to}`);
          const r = await fetch(u, { headers: { 'user-agent': s.ua }, signal });
          if (!r.ok || !r.body) {
            ctl.error(new Error(`stream piece HTTP ${r.status}`));
            return;
          }
          reader = r.body.getReader();
        }
        const { done, value } = await reader.read();
        if (done) {
          reader = null;
          continue;
        }
        pos += value.byteLength;
        ctl.enqueue(value);
        return;
      }
    },
    cancel() {
      ac.abort();
      reader?.cancel().catch(() => {});
    },
  });
}

async function probe(s: Stream): Promise<boolean> {
  const u = new URL(s.url);
  u.searchParams.set('range', '0-1');
  try {
    const r = await fetch(u, { headers: { 'user-agent': s.ua } });
    await r.body?.cancel();
    return r.ok;
  } catch {
    return false;
  }
}

async function play(req: Request, params: URLSearchParams, origin: string | null): Promise<Response> {
  const id = params.get('play') ?? '';
  if (!/^[A-Za-z0-9_-]{11}$/.test(id)) return refuse(400, 'bad video id', origin);
  const q = params.get('q') === 'low' ? 'low' : 'high';
  const mp4 = params.get('f') === 'mp4';
  let s: Stream;
  try {
    s = await resolveStream(id, q, mp4);
    // a link cached by this copy of the function may be from another egress IP
    if (Date.now() - s.at > 30_000 && !(await probe(s))) s = await resolveStream(id, q, mp4, true);
  } catch (e) {
    return refuse(e instanceof PlayError ? e.status : 502, String((e as Error).message ?? e), origin);
  }
  if (!s.length) {
    // unknown length: plain pass-through
    const r = await fetch(s.url, { headers: { 'user-agent': s.ua, ...(req.headers.get('range') ? { range: req.headers.get('range')! } : {}) } });
    return respondUpstream(r, origin, { 'content-type': s.mime, 'x-byte-proxy': `play;${s.client}` });
  }
  const range = parseRange(req.headers.get('range'), s.length);
  const start = range?.start ?? 0;
  const end = range?.end ?? s.length - 1;
  const h = corsHeaders(origin);
  h.set('content-type', s.mime);
  h.set('accept-ranges', 'bytes');
  h.set('content-length', String(end - start + 1));
  h.set('cache-control', 'private, max-age=3600');
  h.set('x-byte-proxy', `play;${s.client}`);
  if (range) h.set('content-range', `bytes ${start}-${end}/${s.length}`);
  if (req.method === 'HEAD') return new Response(null, { status: range ? 206 : 200, headers: h });
  return new Response(pieces(s, start, end), { status: range ? 206 : 200, headers: h });
}

// ---------- the door ----------
export async function handle(req: Request): Promise<Response> {
  const origin = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(origin) });
  const url = new URL(req.url);
  const p = url.searchParams;
  if (p.has('ping')) {
    const h = corsHeaders(origin);
    h.set('content-type', 'application/json');
    return new Response(JSON.stringify({ ok: true, name: 'byte-proxy', v: VERSION }), { headers: h });
  }
  if (!limiter.allow(clientIp(req))) return refuse(429, 'slow down', origin);
  if (p.has('play')) return play(req, p, origin);
  const t = checkTarget(p.get('u'));
  if ('error' in t) return refuse(403, t.error, origin);
  const method = req.method.toUpperCase();
  const hasBody = !['GET', 'HEAD'].includes(method);
  let up: Response;
  try {
    up = await fetch(t.url, {
      method,
      headers: upstreamHeaders(req),
      body: hasBody ? await req.arrayBuffer() : undefined,
      redirect: 'manual',
    });
  } catch (e) {
    return refuse(502, `upstream: ${String((e as Error).message ?? e)}`, origin);
  }
  // follow redirects only while they stay on the allowlist
  for (let hop = 0; hop < 5 && up.status >= 300 && up.status < 400 && up.headers.get('location'); hop++) {
    const next = new URL(up.headers.get('location')!, t.url).toString();
    const n = checkTarget(next);
    if ('error' in n) return respondUpstream(up, origin, { 'x-byte-final-url': next });
    await up.body?.cancel();
    up = await fetch(n.url, { method: up.status === 307 || up.status === 308 ? method : 'GET', headers: upstreamHeaders(req), redirect: 'manual' });
    t.url = n.url;
  }
  return respondUpstream(up, origin, { 'x-byte-final-url': t.url.toString() });
}

// Supabase runs this file as the function; locally: PORT=8790 deno run -A index.ts
// (tests import it with BYTE_PROXY_NO_SERVE=1 so no server starts).
if (!Deno.env.get('BYTE_PROXY_NO_SERVE')) {
  const port = Deno.env.get('PORT');
  if (port) Deno.serve({ port: Number(port) }, handle);
  else Deno.serve(handle);
}
