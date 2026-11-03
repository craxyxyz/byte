package com.apurbalaskar.byteapp

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

// Byte © 2026 Apurba Laskar — Automix: decodes a song on the phone (the
// phone's own MediaCodec decoders) to mono 16-bit PCM at a low sample rate,
// which Byte's Dart code then analyses (tempo, beats, loudness, intro/outro).
object AutomixDecoder {
    fun decode(path: String, outRate: Int, maxSeconds: Int): ByteArray {
        val ex = MediaExtractor()
        try {
            ex.setDataSource(path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until ex.trackCount) {
                val f = ex.getTrackFormat(i)
                if ((f.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    track = i
                    format = f
                    break
                }
            }
            if (track < 0 || format == null) throw IllegalArgumentException("no audio track")
            ex.selectTrack(track)
            val codec = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
            val sink = MonoResampler(outRate, maxSeconds)
            var inRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                val info = MediaCodec.BufferInfo()
                var inputDone = false
                var outputDone = false
                val deadline = System.currentTimeMillis() + 90_000
                while (!outputDone) {
                    if (System.currentTimeMillis() > deadline) throw IllegalStateException("decode took too long")
                    if (!inputDone) {
                        val ii = codec.dequeueInputBuffer(10_000)
                        if (ii >= 0) {
                            val buf = codec.getInputBuffer(ii)
                            val n = if (buf == null) -1 else ex.readSampleData(buf, 0)
                            if (n < 0) {
                                codec.queueInputBuffer(ii, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                codec.queueInputBuffer(ii, 0, n, ex.sampleTime, 0)
                                ex.advance()
                            }
                        }
                    }
                    val oi = codec.dequeueOutputBuffer(info, 10_000)
                    if (oi == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        val f = codec.outputFormat
                        inRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        if (Build.VERSION.SDK_INT >= 24 && f.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            isFloat = f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                        }
                    } else if (oi >= 0) {
                        val buf = codec.getOutputBuffer(oi)
                        if (buf != null && info.size > 0) {
                            buf.position(info.offset)
                            buf.limit(info.offset + info.size)
                            sink.feed(buf.slice().order(ByteOrder.nativeOrder()), inRate, channels, isFloat)
                        }
                        codec.releaseOutputBuffer(oi, false)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0 || sink.full) outputDone = true
                    }
                }
            } finally {
                try {
                    codec.stop()
                } catch (_: Exception) {
                }
                codec.release()
            }
            return sink.bytes()
        } finally {
            ex.release()
        }
    }
}

/// Mixes to mono and averages down to [outRate] (a box filter is plenty for
/// loudness and beat analysis), as little-endian 16-bit samples.
class MonoResampler(private val outRate: Int, maxSeconds: Int) {
    private val maxSamples = outRate.toLong() * maxSeconds
    private val out = ByteArrayOutputStream(outRate * 2 * 240)
    private var acc = 0.0
    private var accN = 0
    private var phase = 0.0
    private var written = 0L
    val full: Boolean get() = written >= maxSamples

    fun feed(buf: ByteBuffer, inRate: Int, channels: Int, isFloat: Boolean) {
        val ch = if (channels < 1) 1 else channels
        val step = outRate.toDouble() / (if (inRate > 0) inRate else 44100)
        if (isFloat) {
            val fb = buf.asFloatBuffer()
            val frames = fb.remaining() / ch
            for (i in 0 until frames) {
                var s = 0.0
                for (c in 0 until ch) s += fb.get()
                push(s / ch * 32767.0, step)
                if (full) return
            }
        } else {
            val sb = buf.asShortBuffer()
            val frames = sb.remaining() / ch
            for (i in 0 until frames) {
                var s = 0
                for (c in 0 until ch) s += sb.get()
                push(s.toDouble() / ch, step)
                if (full) return
            }
        }
    }

    private fun push(v: Double, step: Double) {
        acc += v
        accN++
        phase += step
        while (phase >= 1.0) {
            phase -= 1.0
            val o = (acc / accN).toInt().coerceIn(-32768, 32767)
            out.write(o and 0xff)
            out.write((o shr 8) and 0xff)
            written++
            if (phase < 1.0) {
                acc = 0.0
                accN = 0
            }
        }
    }

    fun bytes(): ByteArray = out.toByteArray()
}
