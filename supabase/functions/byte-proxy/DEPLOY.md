# Byte web server — 1 step (owner)

**English.** The Byte web app runs in a browser. Browsers block a web page from talking to the music catalogue directly, so Byte's web app calls one small function on your own Supabase project, `byte-proxy`. You switch it on once.

**Hinglish.** Byte web browser mein chalta hai. Browser seedha music catalogue se baat nahi karne deta, isliye web app tumhare Supabase project ka ek chhota function `byte-proxy` use karta hai. Bas ek baar on karna hai.

## Option A: Dashboard (no install / kuch install nahi karna)
1. Open https://supabase.com/dashboard/project/ymnmrxgbjgvtavzyohdp/functions
2. **Deploy a new function** → **Via Editor**
3. Function name: `byte-proxy` (exactly / bilkul yahi naam)
4. Delete the sample code and paste the whole of `index.ts` from this folder. **Deploy**.
5. Open the function → **Details** (or Settings) → turn **OFF** "Enforce JWT verification" / "Verify JWT" → **Save**.
   (Songs play through an `<audio>` tag, which can't send a login key. That's why this must be off.)
6. Check: open `https://ymnmrxgbjgvtavzyohdp.supabase.co/functions/v1/byte-proxy?ping=1` in a browser. You should see `{"ok":true,"name":"byte-proxy","v":1}`.

## Option B: Supabase CLI
```
supabase login
supabase functions deploy byte-proxy --project-ref ymnmrxgbjgvtavzyohdp --no-verify-jwt
```
(Run from the folder that contains `supabase/functions/byte-proxy/index.ts`.)

Refresh the Byte web page. The "web server" banner goes away and Home, Search and lyrics load.
Banner hat jayega, Home / Search / lyrics aa jayenge.

## What it does / safety
- Forwards only to a fixed list of hosts (music catalogue, its audio and cover servers, lyrics and import sites). Everything else gets a 403.
- Never forwards or returns cookies. Bodies are not logged.
- Rate limit: 300 requests per minute per IP (set the env var `BYTE_PROXY_RPM` to change it).
- `?play=<id>` finds a song's audio and streams it in the same call, with seeking (Range) support.

## Honest note on playback
Audio servers only stream to the address that asked for the link, and they often refuse data-centre addresses. On the build machine the catalogue/search calls worked through this function, but the audio server refused the stream (403). If songs don't play on the web after deploying, the function answers `stream_blocked` and the web app shows that error. Browsing, search, lyrics, library and settings still work. The phone app is not affected.
Agar web pe gaana na chale (server block), toh browse/search/lyrics phir bhi chalega; phone app pe koi asar nahi.

## Local test
```
PORT=8790 deno run -A index.ts           # serve
BYTE_PROXY_NO_SERVE=1 deno test -A index_test.ts
```
