package com.ryanheise.just_audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Byte © 2026 Apurba Laskar. Runs [ByteFxCore] on float PCM handed to an audio
 * sink that may take it in pieces: the input is copied and processed once, the
 * copy is fed to the sink until it has taken all of it, and only then is the
 * input marked as used. No media3 types here, so it is tested on the JVM.
 */
final class ByteFxFloatFeeder {
    interface Sink {
        /** Writes from b's position; returns true once b has been taken whole. */
        boolean write(ByteBuffer b, long ptsUs) throws Exception;
    }

    private ByteFxCore core;
    private ByteBuffer src;      // the input buffer being worked on
    private int srcPos = -1;
    private long srcPts;
    private ByteBuffer out;      // its processed copy
    private ByteBuffer passing;  // a buffer handed on as it is, not yet taken whole

    void configure(int sampleRate) { core = new ByteFxCore(sampleRate); drop(); }
    void disable() { core = null; drop(); }
    boolean enabled() { return core != null; }

    /** Forget a half-fed buffer (flush / reset). */
    void drop() { src = null; srcPos = -1; passing = null; if (out != null) out.clear().limit(0); }

    /** Same contract as AudioSink.handleBuffer for interleaved stereo float. */
    boolean handle(ByteBuffer in, long ptsUs, Sink sink, ByteFxCore.Params p) throws Exception {
        // A sink that has started on a buffer must get that same buffer again
        // until it has taken all of it (media3 checks this).
        if (passing == in) {
            if (!sink.write(in, ptsUs)) return false;
            passing = null;
            return true;
        }
        final boolean continuing = src == in && srcPts == ptsUs && srcPos == in.position() && out != null && out.hasRemaining();
        if (!continuing) {
            if (core == null || (p.isNeutral() && core.settled(p))) {
                drop();
                // nothing to change: hand it on as it is
                if (sink.write(in, ptsUs)) return true;
                passing = in;
                return false;
            }
            final int bytes = in.remaining();
            final int n = bytes / 4;
            if (out == null || out.capacity() < bytes) out = ByteBuffer.allocateDirect(Math.max(bytes, 4096)).order(ByteOrder.nativeOrder());
            out.clear();
            final ByteBuffer rd = in.duplicate().order(ByteOrder.nativeOrder());
            final float[] f = new float[n];
            for (int i = 0; i < n; i++) f[i] = rd.getFloat();
            core.process(f, n / 2, p);
            for (int i = 0; i < n; i++) out.putFloat(f[i]);
            out.flip();
            src = in; srcPos = in.position(); srcPts = ptsUs;
        }
        if (!sink.write(out, ptsUs)) return false;
        in.position(in.limit());
        src = null; srcPos = -1;
        return true;
    }
}
