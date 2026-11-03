package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;

/**
 * Byte © 2026 Apurba Laskar. Offline render test of Byte's channel stage on
 * the JVM (no phone): real sine waves through ByteFxCore, the 16-bit
 * processor the player uses, and the float feeder used with 32-bit output.
 * Run: tool/run_android_jvm_tests.sh (plain Java, no test framework).
 */
public final class ByteFxOfflineRenderTest {
    static int failures = 0, checks = 0;

    static void check(boolean ok, String what) {
        checks++;
        if (!ok) { failures++; System.out.println("FAIL  " + what); } else System.out.println("ok    " + what);
    }

    static float[] sine(int frames, int rate, double hz, float l, float r) {
        float[] b = new float[frames * 2];
        for (int i = 0; i < frames; i++) {
            float v = (float) Math.sin(2 * Math.PI * hz * i / rate);
            b[2 * i] = v * l; b[2 * i + 1] = v * r;
        }
        return b;
    }

    static double rms(float[] b, int ch, int from) {
        double s = 0; int n = 0;
        for (int i = from; i < b.length / 2; i++) { s += b[2 * i + ch] * b[2 * i + ch]; n++; }
        return Math.sqrt(s / Math.max(1, n));
    }

    static double db(double x) { return 20 * Math.log10(Math.max(1e-9, x)); }

    /** Renders [in] through a fresh core in 512-frame blocks (like the player does). */
    static float[] render(float[] in, int rate, ByteFxCore.Params p) {
        ByteFxCore core = new ByteFxCore(rate);
        float[] out = in.clone();
        int frames = in.length / 2;
        for (int f = 0; f < frames; f += 512) {
            int n = Math.min(512, frames - f);
            float[] blk = new float[n * 2];
            System.arraycopy(out, 2 * f, blk, 0, n * 2);
            core.process(blk, n, p);
            System.arraycopy(blk, 0, out, 2 * f, n * 2);
        }
        return out;
    }

    public static void main(String[] args) throws Exception {
        final int rate = 48000;
        final int skip = 2048; // after the first glide
        float[] leftOnly = sine(rate, rate, 1000, 1f, 0f);

        // neutral: bit-exact passthrough
        float[] n = render(leftOnly, rate, ByteFxCore.Params.NEUTRAL);
        boolean same = true;
        for (int i = 0; i < n.length; i++) same &= n[i] == leftOnly[i];
        check(same, "neutral settings leave the audio untouched");

        // mono: a left-only song comes out of both sides at half level (-6 dB)
        float[] m = render(leftOnly, rate, new ByteFxCore.Params(true, 0f, false, -6f, 700f, 0f, 0.3f));
        check(Math.abs(rms(m, 0, skip) - rms(m, 1, skip)) < 1e-4, "mono: both sides equal");
        check(Math.abs(db(rms(m, 0, skip) / rms(leftOnly, 0, skip)) + 6.02) < 0.1, "mono: -6 dB per side (" + String.format("%.2f", db(rms(m, 0, skip) / rms(leftOnly, 0, skip))) + " dB)");

        // balance: full right silences the left, half right halves it
        float[] both = sine(rate, rate, 440, 1f, 1f);
        float[] br = render(both, rate, new ByteFxCore.Params(false, 1f, false, -6f, 700f, 0f, 0.3f));
        check(rms(br, 0, skip) < 1e-6 && Math.abs(rms(br, 1, skip) - rms(both, 1, skip)) < 1e-6, "balance +1: left silent, right untouched");
        float[] bh = render(both, rate, new ByteFxCore.Params(false, 0.5f, false, -6f, 700f, 0f, 0.3f));
        check(Math.abs(rms(bh, 0, skip) / rms(both, 0, skip) - 0.5) < 1e-3, "balance +0.5: left at half");

        // crossfeed: low notes reach the other ear at about the set level, high notes much less
        ByteFxCore.Params xf = new ByteFxCore.Params(false, 0f, true, -6f, 700f, 1f, 0.3f);
        float[] lo = render(sine(rate, rate, 100, 1f, 0f), rate, xf);
        float[] hi = render(sine(rate, rate, 8000, 1f, 0f), rate, xf);
        double loBleed = db(rms(lo, 1, skip) / rms(lo, 0, skip)), hiBleed = db(rms(hi, 1, skip) / rms(hi, 0, skip));
        check(loBleed > -8 && loBleed < -4, "crossfeed: 100 Hz reaches the other ear at " + String.format("%.1f", loBleed) + " dB (set -6)");
        check(hiBleed < loBleed - 12, "crossfeed: 8 kHz bleeds much less (" + String.format("%.1f", hiBleed) + " dB)");

        // moving a slider never clicks: the change glides across a block
        ByteFxCore core = new ByteFxCore(rate);
        float[] dc = new float[1024]; java.util.Arrays.fill(dc, 0.8f);
        core.process(dc, 512, ByteFxCore.Params.NEUTRAL);
        float[] step = new float[1024]; java.util.Arrays.fill(step, 0.8f);
        core.process(step, 512, new ByteFxCore.Params(false, 1f, false, -6f, 700f, 0f, 0.3f));
        double maxJump = 0;
        for (int i = 1; i < 512; i++) maxJump = Math.max(maxJump, Math.abs(step[2 * i] - step[2 * i - 2]));
        check(maxJump < 0.01, "balance jump to +1 glides (largest step " + String.format("%.4f", maxJump) + ")");

        // the 16-bit processor the player runs: configure, process, same result as the core
        ByteFxCore.current = new ByteFxCore.Params(true, 0f, false, -6f, 700f, 0f, 0.3f);
        ByteFxProcessor proc = new ByteFxProcessor();
        AudioProcessor.AudioFormat fmt = proc.configure(new AudioProcessor.AudioFormat(rate, 2, C.ENCODING_PCM_16BIT));
        proc.flush();
        check(proc.isActive() && fmt.encoding == C.ENCODING_PCM_16BIT, "16-bit processor takes stereo 16-bit");
        int diff = 0;
        for (int block = 0; block < 2; block++) { // the first block carries the glide
            ByteBuffer pcm = ByteBuffer.allocateDirect(960 * 4).order(ByteOrder.nativeOrder());
            for (int i = 0; i < 960; i++) { pcm.putShort((short) (16000 * Math.sin(2 * Math.PI * 1000 * (i + block * 960) / rate))); pcm.putShort((short) 0); }
            pcm.flip();
            proc.queueInput(pcm);
            ByteBuffer o = proc.getOutput();
            for (int i = 0; i < 960; i++) { short l = o.getShort(), r = o.getShort(); if (block == 1) diff = Math.max(diff, Math.abs(l - r)); }
        }
        check(diff <= 1, "16-bit processor: mono makes both sides equal (max diff " + diff + ")");
        AudioProcessor.AudioFormat mono51 = null;
        try { mono51 = new ByteFxProcessor().configure(new AudioProcessor.AudioFormat(rate, 6, C.ENCODING_PCM_16BIT)); } catch (Exception e) { }
        check(mono51 == AudioProcessor.AudioFormat.NOT_SET, "5.1 audio passes through untouched (stage stays off)");

        // float feeder (32-bit output): a sink that takes a third at a time
        ByteFxFloatFeeder feeder = new ByteFxFloatFeeder();
        feeder.configure(rate);
        final List<Float> got = new ArrayList<>();
        ByteFxFloatFeeder.Sink third = (b, pts) -> {
            int take = Math.min(b.remaining(), 4 * 2 * 160);
            for (int i = 0; i < take / 4; i++) got.add(b.order(ByteOrder.nativeOrder()).getFloat());
            return !b.hasRemaining();
        };
        float[] src = sine(480, rate, 1000, 1f, 0f);
        ByteBuffer in = ByteBuffer.allocateDirect(src.length * 4).order(ByteOrder.nativeOrder());
        for (float v : src) in.putFloat(v);
        in.flip();
        ByteFxCore.Params mono = new ByteFxCore.Params(true, 0f, false, -6f, 700f, 0f, 0.3f);
        int calls = 0; boolean done = false;
        while (!done && calls < 20) { done = feeder.handle(in, 1000, third, mono); calls++; if (!done) check(in.position() == 0, "float: input not marked used while the sink is still taking it (call " + calls + ")"); }
        check(done && calls == 3 && !in.hasRemaining(), "float: taken in 3 pieces, then the input is used up");
        float[] want = render(src, rate, mono);
        boolean eq = got.size() == want.length;
        for (int i = 0; eq && i < want.length; i++) eq = Math.abs(got.get(i) - want[i]) < 1e-6;
        check(eq, "float: every sample processed exactly once (" + got.size() + " samples)");
        // neutral → handed on as is (same buffer object)
        final ByteBuffer[] seen = new ByteBuffer[1];
        ByteBuffer in2 = ByteBuffer.allocateDirect(64).order(ByteOrder.nativeOrder());
        in2.putFloat(0.5f).flip();
        ByteFxFloatFeeder f2 = new ByteFxFloatFeeder(); f2.configure(rate);
        f2.handle(in2, 0, (b, pts) -> { seen[0] = b; b.position(b.limit()); return true; }, ByteFxCore.Params.NEUTRAL);
        check(seen[0] == in2, "float: neutral audio goes to the sink untouched (no copy)");
        // a sink that started on the original buffer keeps getting it, even if mono is switched on mid-way
        ByteBuffer in3 = ByteBuffer.allocateDirect(80).order(ByteOrder.nativeOrder());
        for (int i = 0; i < 20; i++) in3.putFloat(0.1f);
        in3.flip();
        final List<ByteBuffer> handed = new ArrayList<>();
        ByteFxFloatFeeder.Sink half = (b, pts) -> { handed.add(b); b.position(Math.min(b.limit(), b.position() + 40)); return !b.hasRemaining(); };
        ByteFxFloatFeeder f3 = new ByteFxFloatFeeder(); f3.configure(rate);
        boolean r1 = f3.handle(in3, 5, half, ByteFxCore.Params.NEUTRAL);
        boolean r2 = f3.handle(in3, 5, half, mono);
        check(!r1 && r2 && handed.get(0) == in3 && handed.get(1) == in3, "float: a half-taken buffer is never swapped for a copy");

        System.out.println((checks - failures) + "/" + checks + " checks passed");
        if (failures > 0) System.exit(1);
    }
}
