# © 2026 Apurba Laskar
# Prints the mean level (dB) of what the default speaker plays for N seconds
# (Windows loopback; CI sound check for the desktop build).
import math, sys
import numpy as np
import soundcard as sc
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 2.0
spk = sc.default_speaker()
mic = sc.get_microphone(id=str(spk.name), include_loopback=True)
with mic.recorder(samplerate=48000, channels=2) as r:
    d = r.record(numframes=int(48000 * secs))
v = float(np.sqrt(np.mean(np.square(d)))) if d.size else 0.0
print(f"{20 * math.log10(v):.1f}" if v > 0 else "-999")
