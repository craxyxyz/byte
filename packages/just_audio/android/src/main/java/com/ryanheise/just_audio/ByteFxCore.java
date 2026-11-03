package com.ryanheise.just_audio;

/**
 * Byte © 2026 Apurba Laskar. Byte's own channel effects on the audio path:
 * balance, mono, and headphone crossfeed (a low-passed, slightly delayed copy
 * of each side mixed into the other, like hearing speakers in a room). Pure
 * Java so it can be tested off the phone. Parameter changes glide across one
 * buffer, so moving a slider never clicks.
 */
public final class ByteFxCore {
    /** What the person set (read by every player's processor). */
    public static final class Params {
        public final boolean mono;
        public final float balance;      // -1 left … +1 right
        public final boolean crossfeed;
        public final float crossfeedDb;  // level of the other side, e.g. -6 (dB)
        public final float cutoffHz;     // head-shadow low-pass, e.g. 700
        public final float amount;       // 0 … 1 wet
        public final float delayMs;      // 0.1 … 0.6
        public Params(boolean mono, float balance, boolean crossfeed, float crossfeedDb, float cutoffHz, float amount, float delayMs) {
            this.mono = mono; this.balance = balance; this.crossfeed = crossfeed; this.crossfeedDb = crossfeedDb;
            this.cutoffHz = cutoffHz; this.amount = amount; this.delayMs = delayMs;
        }
        public boolean isNeutral() { return !mono && Math.abs(balance) < 1e-4f && (!crossfeed || amount <= 0f); }
        public static final Params NEUTRAL = new Params(false, 0f, false, -6f, 700f, 0f, 0.3f);
    }

    public static volatile Params current = Params.NEUTRAL;
    /** 32-bit float output (Playback → Output precision); read when a player starts. */
    public static volatile boolean floatOutput = false;

    private final int sampleRate;
    // smoothed (applied) values
    private float gL = 1f, gR = 1f, monoMix = 0f, xf = 0f;
    // crossfeed state
    private float lpL = 0f, lpR = 0f;
    private final float[] dlL = new float[64], dlR = new float[64];
    private int dlPos = 0;

    public ByteFxCore(int sampleRate) { this.sampleRate = Math.max(8000, sampleRate); }

    static float targetGainL(Params p) { return p.balance > 0 ? 1f - p.balance : 1f; }
    static float targetGainR(Params p) { return p.balance < 0 ? 1f + p.balance : 1f; }

    /** Processes interleaved stereo float samples in place. */
    public void process(float[] buf, int frames, Params p) {
        final float tL = targetGainL(p), tR = targetGainR(p);
        final float tMono = p.mono ? 1f : 0f;
        final float tXf = p.crossfeed ? Math.max(0f, Math.min(1f, p.amount)) : 0f;
        final float level = (float) Math.pow(10.0, Math.min(0f, p.crossfeedDb) / 20.0);
        final float a = (float) (1.0 - Math.exp(-2.0 * Math.PI * Math.max(100f, Math.min(4000f, p.cutoffHz)) / sampleRate));
        final int delay = Math.max(1, Math.min(63, Math.round(p.delayMs / 1000f * sampleRate)));
        final float sL0 = gL, sR0 = gR, sM0 = monoMix, sX0 = xf;
        for (int i = 0; i < frames; i++) {
            final float t = frames <= 1 ? 1f : (float) i / (frames - 1);
            final float cgL = sL0 + (tL - sL0) * t, cgR = sR0 + (tR - sR0) * t;
            final float cm = sM0 + (tMono - sM0) * t, cx = sX0 + (tXf - sX0) * t;
            float l = buf[2 * i], r = buf[2 * i + 1];
            // crossfeed: low-passed, delayed other side
            lpL += a * (l - lpL);
            lpR += a * (r - lpR);
            dlL[dlPos] = lpL;
            dlR[dlPos] = lpR;
            final int rd = (dlPos - delay + 64) & 63;
            dlPos = (dlPos + 1) & 63;
            if (cx > 0f) {
                final float norm = 1f / (1f + level * cx);
                final float nl = (l + cx * level * dlR[rd]) * norm;
                final float nr = (r + cx * level * dlL[rd]) * norm;
                l = nl; r = nr;
            }
            // mono
            if (cm > 0f) {
                final float m = 0.5f * (l + r);
                l = l + (m - l) * cm;
                r = r + (m - r) * cm;
            }
            buf[2 * i] = l * cgL;
            buf[2 * i + 1] = r * cgR;
        }
        gL = tL; gR = tR; monoMix = tMono; xf = tXf;
    }

    /** True while the last change is still gliding (keep processing). */
    public boolean settled(Params p) {
        return gL == targetGainL(p) && gR == targetGainR(p) && monoMix == (p.mono ? 1f : 0f) && xf == (p.crossfeed ? Math.max(0f, Math.min(1f, p.amount)) : 0f);
    }
}
