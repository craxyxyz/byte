package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/**
 * Byte © 2026 Apurba Laskar. With 32-bit float output on, media3's audio sink
 * leaves its processor chain out for float audio, so Byte's balance / mono /
 * crossfeed stage ([ByteFxProcessor]) would silently do nothing. This wrapper
 * runs the same stage on the float audio before it reaches the sink.
 */
final class ByteFxSink extends ForwardingAudioSink {
    private final ByteFxFloatFeeder feeder = new ByteFxFloatFeeder();
    private final ByteFxFloatFeeder.Sink down = (b, pts) -> ByteFxSink.super.handleBuffer(b, pts, 1);

    ByteFxSink(AudioSink sink) { super(sink); }

    @Override
    public void configure(Format f, int specifiedBufferSize, int[] outputChannels) throws ConfigurationException {
        if (MimeTypes.AUDIO_RAW.equals(f.sampleMimeType) && f.pcmEncoding == C.ENCODING_PCM_FLOAT && f.channelCount == 2) {
            feeder.configure(f.sampleRate);
        } else {
            feeder.disable(); // 16-bit audio goes through ByteFxProcessor in the sink's own chain
        }
        super.configure(f, specifiedBufferSize, outputChannels);
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount) throws InitializationException, WriteException {
        if (!feeder.enabled()) return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
        try {
            return feeder.handle(buffer, presentationTimeUs, down, ByteFxCore.current);
        } catch (InitializationException | WriteException e) {
            throw e;
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    @Override
    public void flush() { feeder.drop(); super.flush(); }

    @Override
    public void reset() { feeder.drop(); super.reset(); }
}
