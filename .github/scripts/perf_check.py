# © 2026 Apurba Laskar
# Byte desktop smoothness check (1.4.5.2). Runs the real app with
# BYTE_PERFTEST=1: a local song with synced lyrics and a cover, 15 s each on
# Home playing, player playing, player paused, Home paused. Samples the app's
# CPU once a second and reads the frames it drew. A paused screen must draw
# (almost) nothing and use (almost) no CPU; a playing player must not redraw
# at the screen's full refresh rate.
#   python perf_check.py <path to Byte.exe or byte>
import json, math, os, struct, subprocess, sys, tempfile, time, wave, zlib

import psutil

exe = os.path.abspath(sys.argv[1])
work = tempfile.mkdtemp(prefix='byteperf')
song = os.path.join(work, 'song.wav')
with wave.open(song, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
    w.writeframes(b''.join(struct.pack('<h', int(8000 * math.sin(2 * math.pi * 330 * i / 22050))) for i in range(22050 * 150)))
cover = os.path.join(work, 'cover.png')
W = H = 256
raw = b''.join(b'\x00' + bytes(v for x in range(W) for v in (x, y, 255 - x // 2)) for y in range(H))
def chunk(t, d): return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
open(cover, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
out = os.path.join(work, 'perf.jsonl')
env = dict(os.environ, BYTE_PERFTEST='1', BYTE_PERFTEST_OUT=out, BYTE_SELFTEST_FILES=song, BYTE_PERFTEST_COVER=cover, BYTE_PERFTEST_EXIT='1', BYTE_PERFTEST_SECS=os.environ.get('BYTE_PERFTEST_SECS', '15'))
proc = subprocess.Popen([exe], env=env, cwd=os.path.dirname(exe), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
p = psutil.Process(proc.pid)
cpu = []  # (epoch ms, cpu seconds)
t0 = time.time()
while proc.poll() is None and time.time() - t0 < 180:
    try:
        ct = p.cpu_times()
        cpu.append((time.time() * 1000, ct.user + ct.system))
    except psutil.Error:
        break
    time.sleep(1)
if proc.poll() is None:
    proc.kill()
lines = [json.loads(l) for l in open(out, encoding='utf-8')] if os.path.exists(out) else []
marks = [(l['epoch'], l['phase']) for l in lines if 'phase' in l and 'frames' not in l]
phases = ['home_playing', 'player_playing', 'player_paused', 'home_paused']
res = {}
for i, (start, name) in enumerate(marks):
    if name not in phases:
        continue
    end = marks[i + 1][0] if i + 1 < len(marks) else start + 15000
    a, b = start + 6000, end  # skip the first 6 s (screen change, pause fade, controls folding)
    fr = [l for l in lines if 'frames' in l and a < l['epoch'] <= b]
    fps = sum(l['frames'] for l in fr) / max(1, len(fr))
    raster = [l['rasterMs'] for l in fr if l['frames']]
    cs = [c for c in cpu if a <= c[0] <= b]
    pct = (cs[-1][1] - cs[0][1]) / ((cs[-1][0] - cs[0][0]) / 1000) * 100 if len(cs) > 2 else float('nan')
    res[name] = {'frames_per_s': round(fps, 1), 'cpu_pct_of_one_core': round(pct, 1), 'raster_ms': round(sum(raster) / len(raster), 2) if raster else 0}
errors = [l for l in lines if 'perftest_error' in l]
report = '\n'.join(f'[perf] {k}: {v["frames_per_s"]} frames/s, CPU {v["cpu_pct_of_one_core"]} % of one core, raster {v["raster_ms"]} ms' for k, v in res.items())
report += ''.join(f'\n[perf] error: {e["perftest_error"]}' for e in errors)
print(report)
print(json.dumps(res))
if os.environ.get('GITHUB_ACTIONS'):
    print('::notice title=smoothness check::' + report.replace('%', '%25').replace('\n', '%0A'))
bad = []
opened = [l for l in lines if 'opened' in l]
if not opened or not opened[0]['opened']:
    bad.append('the player screen did not open')
for k in phases:
    if k not in res:
        bad.append(f'{k}: not measured')
for k in ('player_paused', 'home_paused'):
    if k in res and res[k]['frames_per_s'] > 2:
        bad.append(f'{k}: {res[k]["frames_per_s"]} frames/s while nothing moves')
if 'player_playing' in res and res['player_playing']['frames_per_s'] > 40:
    bad.append(f'player_playing: {res["player_playing"]["frames_per_s"]} frames/s (redraws at full refresh)')
limit = float(os.environ.get('BYTE_PERF_PAUSED_CPU', '15'))
for k in ('player_paused', 'home_paused'):
    if k in res and res[k]['cpu_pct_of_one_core'] > limit:
        bad.append(f'{k}: CPU {res[k]["cpu_pct_of_one_core"]} % while paused')
if bad:
    print('[perf] FAIL: ' + '; '.join(bad))
    sys.exit(1)
print('[perf] OK')
