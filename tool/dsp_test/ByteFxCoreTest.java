import com.ryanheise.just_audio.ByteFxCore;

public class ByteFxCoreTest {
    static int fails = 0;
    static void check(boolean ok, String what) { System.out.println((ok ? "PASS " : "FAIL ") + what); if (!ok) fails++; }
    static float[] sine(int frames, float fL, float fR, int sr, float ampL, float ampR) {
        float[] b = new float[frames * 2];
        for (int i = 0; i < frames; i++) { b[2*i] = (float)(ampL*Math.sin(2*Math.PI*fL*i/sr)); b[2*i+1] = (float)(ampR*Math.sin(2*Math.PI*fR*i/sr)); }
        return b;
    }
    static double rms(float[] b, int ch) { double s=0; int n=b.length/2; for (int i=0;i<n;i++) s+=b[2*i+ch]*b[2*i+ch]; return Math.sqrt(s/n); }
    static double maxStep(float[] b, int ch) { double m=0; for (int i=1;i<b.length/2;i++) m=Math.max(m, Math.abs(b[2*i+ch]-b[2*(i-1)+ch])); return m; }
    public static void main(String[] a) {
        int sr = 48000;
        // neutral passes through exactly
        ByteFxCore c = new ByteFxCore(sr);
        float[] x = sine(4800, 440, 440, sr, 0.5f, 0.5f), y = x.clone();
        c.process(y, 4800, ByteFxCore.Params.NEUTRAL);
        boolean same = true; for (int i=0;i<x.length;i++) if (Math.abs(x[i]-y[i])>1e-7) same=false;
        check(same, "neutral settings leave the sound untouched");
        // mono: left-only input ends up equal on both sides
        c = new ByteFxCore(sr);
        ByteFxCore.Params mono = new ByteFxCore.Params(true, 0f, false, -6f, 700f, 0f, 0.3f);
        float[] lOnly = sine(4800, 440, 440, sr, 0.5f, 0f);
        c.process(lOnly, 4800, mono); // glide-in buffer
        float[] lOnly2 = sine(4800, 440, 440, sr, 0.5f, 0f);
        c.process(lOnly2, 4800, mono);
        double dl = rms(lOnly2,0), dr = rms(lOnly2,1);
        check(Math.abs(dl-dr) < 1e-4 && dr > 0.1, "mono: one-sided song plays equally on both sides (L " + dl + " R " + dr + ")");
        // balance full right silences left
        c = new ByteFxCore(sr);
        ByteFxCore.Params right = new ByteFxCore.Params(false, 1f, false, -6f, 700f, 0f, 0.3f);
        float[] s1 = sine(4800, 440, 440, sr, 0.5f, 0.5f); c.process(s1, 4800, right);
        float[] s2 = sine(4800, 440, 440, sr, 0.5f, 0.5f); c.process(s2, 4800, right);
        check(rms(s2,0) < 1e-6 && rms(s2,1) > 0.3, "balance right: left silent, right full");
        // crossfeed: low frequencies leak to the other side, high frequencies much less
        ByteFxCore.Params xf = new ByteFxCore.Params(false, 0f, true, -4.5f, 700f, 1f, 0.3f);
        c = new ByteFxCore(sr);
        float[] lowL = sine(9600, 100, 100, sr, 0.5f, 0f); c.process(lowL, 9600, xf);
        lowL = sine(9600, 100, 100, sr, 0.5f, 0f); c.process(lowL, 9600, xf);
        c = new ByteFxCore(sr);
        float[] hiL = sine(9600, 8000, 8000, sr, 0.5f, 0f); c.process(hiL, 9600, xf);
        hiL = sine(9600, 8000, 8000, sr, 0.5f, 0f); c.process(hiL, 9600, xf);
        double lowLeak = rms(lowL,1)/rms(lowL,0), hiLeak = rms(hiL,1)/rms(hiL,0);
        check(lowLeak > 0.4 && lowLeak < 0.8, "crossfeed: bass reaches the other ear at about -4.5 dB (" + lowLeak + ")");
        check(hiLeak < lowLeak / 4, "crossfeed: treble mostly stays on its side, like a head shadow (" + hiLeak + ")");
        // no clicks: switching mono on mid-song glides (largest sample step stays near the signal's own)
        c = new ByteFxCore(sr);
        float[] pre = sine(4800, 220, 220, sr, 0.5f, -0.5f); c.process(pre, 4800, ByteFxCore.Params.NEUTRAL);
        double natural = maxStep(sine(4800, 220, 220, sr, 0.5f, -0.5f), 0);
        float[] sw = new float[0];
        // continue the same waveform phase
        float[] cont = new float[4800*2];
        for (int i=0;i<4800;i++){ cont[2*i]=(float)(0.5*Math.sin(2*Math.PI*220*(i+4800)/sr)); cont[2*i+1]=-cont[2*i]; }
        c.process(cont, 4800, mono);
        check(maxStep(cont,0) <= natural * 1.05, "switching mono on mid-song doesn't click (step " + maxStep(cont,0) + " vs " + natural + ")");
        // output never louder than input with crossfeed (normalised)
        c = new ByteFxCore(sr);
        float[] loud = sine(9600, 100, 100, sr, 0.9f, 0.9f); c.process(loud, 9600, xf);
        float mx = 0; for (float v : loud) mx = Math.max(mx, Math.abs(v));
        check(mx <= 0.9f + 1e-3f, "crossfeed never pushes a full song into clipping (peak " + mx + ")");
        System.out.println(fails == 0 ? "ALL PASS" : (fails + " FAILED"));
        System.exit(fails == 0 ? 0 : 1);
    }
}
