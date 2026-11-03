package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Byte © 2026 Apurba Laskar. Runs [ByteFxCore] on the player's PCM (16-bit or float, stereo). */
final class ByteFxProcessor extends BaseAudioProcessor {
    private ByteFxCore core;
    private float[] scratch = new float[0];
    private int encoding;

    @Override
    protected AudioFormat onConfigure(AudioFormat in) throws UnhandledAudioFormatException {
        if (in.channelCount != 2 || (in.encoding != C.ENCODING_PCM_16BIT && in.encoding != C.ENCODING_PCM_FLOAT)) {
            return AudioFormat.NOT_SET; // inactive: passes through untouched
        }
        encoding = in.encoding;
        core = new ByteFxCore(in.sampleRate);
        return in;
    }

    @Override
    public void queueInput(ByteBuffer input) {
        final int remaining = input.remaining();
        if (remaining == 0) return;
        final ByteFxCore.Params p = ByteFxCore.current;
        final ByteBuffer out = replaceOutputBuffer(remaining);
        if (core == null || (p.isNeutral() && core.settled(p))) {
            out.put(input);
            out.flip();
            return;
        }
        final ByteBuffer in = input.order(ByteOrder.nativeOrder());
        if (encoding == C.ENCODING_PCM_FLOAT) {
            final int n = remaining / 4;
            if (scratch.length < n) scratch = new float[n];
            for (int i = 0; i < n; i++) scratch[i] = in.getFloat();
            core.process(scratch, n / 2, p);
            for (int i = 0; i < n; i++) out.putFloat(scratch[i]);
        } else {
            final int n = remaining / 2;
            if (scratch.length < n) scratch = new float[n];
            for (int i = 0; i < n; i++) scratch[i] = in.getShort() / 32768f;
            core.process(scratch, n / 2, p);
            for (int i = 0; i < n; i++) {
                float v = scratch[i] * 32768f;
                if (v > 32767f) v = 32767f; else if (v < -32768f) v = -32768f;
                out.putShort((short) Math.round(v));
            }
        }
        out.flip();
    }

    @Override
    protected void onReset() { core = null; }
}
