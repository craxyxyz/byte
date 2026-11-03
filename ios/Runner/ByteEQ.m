// Byte © 2026 Apurba Laskar — equalizer for the iPhone player.
//
// The iPhone audio player has no equalizer setting, so Byte adds one itself:
// every AVPlayerItem that is queued gets an MTAudioProcessingTap (Apple's hook
// for processing a player's audio), and the tap runs a chain of peaking
// filters (one per band) over the samples. If anything is unavailable the
// sound simply passes through unchanged.
#import "ByteEQ.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <objc/runtime.h>
#import <math.h>
#import <stdatomic.h>

#define BYTE_EQ_MAX_BANDS 10
#define BYTE_EQ_MAX_CH 8

// Settings shared with the audio thread.
static float gFreq[BYTE_EQ_MAX_BANDS];
static float gGain[BYTE_EQ_MAX_BANDS];
static atomic_int gBands = 0;
static atomic_int gEnabled = 0;
static atomic_int gVersion = 1;
// 1.4.5 Audio Lab: balance (-1000 left … +1000 right) and mono.
static atomic_int gBalanceMilli = 0;
static atomic_int gMono = 0;
static inline void channelStage(float *l, float *r, float gl, float gr, int mono) {
  float a = *l, b = *r;
  if (mono) {
    float m = 0.5f * (a + b);
    a = m;
    b = m;
  }
  *l = a * gl;
  *r = b * gr;
}

// Automix bass swap: a high-pass filter on one song (found by its file name)
// swept up while the next song comes in. Up to 4 songs at once.
#define BYTE_CUT_SLOTS 4
static _Atomic uint64_t gCutKey[BYTE_CUT_SLOTS];
static _Atomic int gCutMilli[BYTE_CUT_SLOTS]; // amount × 1000

static uint64_t byteKeyFor(NSString *name) {
  if (name.length == 0) return 0;
  const char *s = name.UTF8String;
  uint64_t h = 1469598103934665603ULL;
  while (*s) {
    h ^= (unsigned char)*s++;
    h *= 1099511628211ULL;
  }
  return h == 0 ? 1 : h;
}

static float cutFor(uint64_t key) {
  if (key == 0) return 0;
  for (int i = 0; i < BYTE_CUT_SLOTS; i++) {
    if (atomic_load(&gCutKey[i]) == key) return atomic_load(&gCutMilli[i]) / 1000.0f;
  }
  return 0;
}

typedef struct {
  double b0, b1, b2, a1, a2;
} Biquad;

typedef struct {
  int channels;
  int interleaved;
  double rate;
  int version;
  int bands;
  float preamp;
  Biquad coef[BYTE_EQ_MAX_BANDS];
  // Filter memory per channel per band (direct form I).
  double x1[BYTE_EQ_MAX_CH][BYTE_EQ_MAX_BANDS], x2[BYTE_EQ_MAX_CH][BYTE_EQ_MAX_BANDS];
  double y1[BYTE_EQ_MAX_CH][BYTE_EQ_MAX_BANDS], y2[BYTE_EQ_MAX_CH][BYTE_EQ_MAX_BANDS];
  int isFloat;
  // bass swap
  uint64_t key;
  float hpAmount;
  Biquad hp;
  double hx1[BYTE_EQ_MAX_CH], hx2[BYTE_EQ_MAX_CH], hy1[BYTE_EQ_MAX_CH], hy2[BYTE_EQ_MAX_CH];
} TapState;

static void computeHighPass(TapState *s, float amount) {
  // 20 Hz (nothing) up to ~350 Hz (the kick and bass gone)
  double f = 20.0 * pow(350.0 / 20.0, amount);
  double w0 = 2.0 * M_PI * f / s->rate, cw = cos(w0), alpha = sin(w0) / (2.0 * 0.7071);
  double a0 = 1.0 + alpha;
  s->hp.b0 = (1.0 + cw) / 2.0 / a0;
  s->hp.b1 = -(1.0 + cw) / a0;
  s->hp.b2 = (1.0 + cw) / 2.0 / a0;
  s->hp.a1 = -2.0 * cw / a0;
  s->hp.a2 = (1.0 - alpha) / a0;
  s->hpAmount = amount;
}

static inline float runHighPass(TapState *s, int ch, float in) {
  Biquad *c = &s->hp;
  double x = in;
  double y = c->b0 * x + c->b1 * s->hx1[ch] + c->b2 * s->hx2[ch] - c->a1 * s->hy1[ch] - c->a2 * s->hy2[ch];
  s->hx2[ch] = s->hx1[ch];
  s->hx1[ch] = x;
  s->hy2[ch] = s->hy1[ch];
  s->hy1[ch] = y;
  return (float)y;
}

static void computeCoefficients(TapState *s) {
  int n = atomic_load(&gBands);
  if (n > BYTE_EQ_MAX_BANDS) n = BYTE_EQ_MAX_BANDS;
  float maxGain = 0;
  for (int i = 0; i < n; i++) {
    double f = gFreq[i], g = gGain[i];
    if (g > maxGain) maxGain = (float)g;
    if (f <= 0 || f >= s->rate / 2.0) f = fmin(fmax(f, 20.0), s->rate / 2.0 - 100.0);
    const double Q = 1.1;
    double A = pow(10.0, g / 40.0);
    double w0 = 2.0 * M_PI * f / s->rate;
    double alpha = sin(w0) / (2.0 * Q);
    double cw = cos(w0);
    double a0 = 1.0 + alpha / A;
    s->coef[i].b0 = (1.0 + alpha * A) / a0;
    s->coef[i].b1 = (-2.0 * cw) / a0;
    s->coef[i].b2 = (1.0 - alpha * A) / a0;
    s->coef[i].a1 = (-2.0 * cw) / a0;
    s->coef[i].a2 = (1.0 - alpha / A) / a0;
  }
  s->bands = n;
  // Leave headroom so boosted bands don't clip.
  s->preamp = maxGain > 0 ? powf(10.0f, -maxGain / 20.0f) : 1.0f;
  s->version = atomic_load(&gVersion);
}

static inline float runChain(TapState *s, int ch, float in) {
  double x = in;
  for (int b = 0; b < s->bands; b++) {
    Biquad *c = &s->coef[b];
    double y = c->b0 * x + c->b1 * s->x1[ch][b] + c->b2 * s->x2[ch][b] - c->a1 * s->y1[ch][b] - c->a2 * s->y2[ch][b];
    s->x2[ch][b] = s->x1[ch][b];
    s->x1[ch][b] = x;
    s->y2[ch][b] = s->y1[ch][b];
    s->y1[ch][b] = y;
    x = y;
  }
  return (float)x;
}

static void tapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
  TapState *s = calloc(1, sizeof(TapState));
  if (s) s->key = (uint64_t)(uintptr_t)clientInfo;
  *tapStorageOut = s;
}

static void tapFinalize(MTAudioProcessingTapRef tap) {
  TapState *s = (TapState *)MTAudioProcessingTapGetStorage(tap);
  free(s);
}

static void tapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *fmt) {
  TapState *s = (TapState *)MTAudioProcessingTapGetStorage(tap);
  if (!s || !fmt) return;
  s->channels = (int)fmt->mChannelsPerFrame;
  if (s->channels > BYTE_EQ_MAX_CH) s->channels = BYTE_EQ_MAX_CH;
  s->interleaved = (fmt->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 0 : 1;
  s->isFloat = (fmt->mFormatFlags & kAudioFormatFlagIsFloat) && fmt->mBitsPerChannel == 32;
  s->rate = fmt->mSampleRate > 0 ? fmt->mSampleRate : 44100.0;
  memset(s->x1, 0, sizeof(s->x1));
  memset(s->x2, 0, sizeof(s->x2));
  memset(s->y1, 0, sizeof(s->y1));
  memset(s->y2, 0, sizeof(s->y2));
  memset(s->hx1, 0, sizeof(s->hx1));
  memset(s->hx2, 0, sizeof(s->hx2));
  memset(s->hy1, 0, sizeof(s->hy1));
  memset(s->hy2, 0, sizeof(s->hy2));
  s->hpAmount = 0;
  computeCoefficients(s);
}

static void tapUnprepare(MTAudioProcessingTapRef tap) {}

static void tapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags,
                       AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut) {
  OSStatus err = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, NULL, numberFramesOut);
  if (err != noErr) return;
  TapState *s = (TapState *)MTAudioProcessingTapGetStorage(tap);
  if (!s || !s->isFloat) return;
  int eqOn = atomic_load(&gEnabled);
  float cut = cutFor(s->key);
  if (cut < 0.01f) cut = 0;
  if (cut != s->hpAmount) {
    if (cut == 0) {
      s->hpAmount = 0;
      memset(s->hx1, 0, sizeof(s->hx1));
      memset(s->hx2, 0, sizeof(s->hx2));
      memset(s->hy1, 0, sizeof(s->hy1));
      memset(s->hy2, 0, sizeof(s->hy2));
    } else {
      computeHighPass(s, cut);
    }
  }
  int hpOn = s->hpAmount > 0;
  if (eqOn && s->version != atomic_load(&gVersion)) computeCoefficients(s);
  int eqRun = eqOn && s->bands > 0;
  int balMilli = atomic_load(&gBalanceMilli);
  int monoOn = atomic_load(&gMono);
  float bal = balMilli / 1000.0f;
  float gl = bal > 0 ? 1.0f - bal : 1.0f, gr = bal < 0 ? 1.0f + bal : 1.0f;
  int chRun = monoOn || balMilli != 0;
  if (!eqRun && !hpOn && !chRun) return;
  float pre = eqRun ? s->preamp : 1.0f;
  CMItemCount frames = *numberFramesOut;
  for (UInt32 bi = 0; bi < bufferListInOut->mNumberBuffers; bi++) {
    AudioBuffer *buf = &bufferListInOut->mBuffers[bi];
    float *d = (float *)buf->mData;
    if (!d) continue;
    if (s->interleaved) {
      int chs = (int)buf->mNumberChannels;
      if (chs > BYTE_EQ_MAX_CH) chs = BYTE_EQ_MAX_CH;
      for (CMItemCount f = 0; f < frames; f++) {
        for (int c = 0; c < chs; c++) {
          float *p = &d[f * buf->mNumberChannels + c];
          float v = *p * pre;
          if (eqRun) v = runChain(s, c, v);
          if (hpOn) v = runHighPass(s, c, v);
          *p = v;
        }
        if (chRun && buf->mNumberChannels == 2) channelStage(&d[f * 2], &d[f * 2 + 1], gl, gr, monoOn);
      }
    } else {
      int c = (int)bi < BYTE_EQ_MAX_CH ? (int)bi : BYTE_EQ_MAX_CH - 1;
      for (CMItemCount f = 0; f < frames; f++) {
        float v = d[f] * pre;
        if (eqRun) v = runChain(s, c, v);
        if (hpOn) v = runHighPass(s, c, v);
        d[f] = v;
      }
    }
  }
  // Non-interleaved stereo: left and right are two buffers.
  if (chRun && !s->interleaved && bufferListInOut->mNumberBuffers == 2) {
    float *l = (float *)bufferListInOut->mBuffers[0].mData, *r = (float *)bufferListInOut->mBuffers[1].mData;
    if (l && r) {
      for (CMItemCount f = 0; f < frames; f++) channelStage(&l[f], &r[f], gl, gr, monoOn);
    }
  }
}

static void attachTap(AVPlayerItem *item) {
  if (!item || objc_getAssociatedObject(item, "byteEQ")) return;
  objc_setAssociatedObject(item, "byteEQ", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  AVAsset *asset = item.asset;
  uint64_t key = 0;
  if ([asset isKindOfClass:[AVURLAsset class]]) {
    NSURL *url = ((AVURLAsset *)asset).URL;
    if (url.isFileURL) key = byteKeyFor(url.lastPathComponent);
  }
  __weak AVPlayerItem *weakItem = item;
  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                       completionHandler:^{
                         dispatch_async(dispatch_get_main_queue(), ^{
                           AVPlayerItem *it = weakItem;
                           if (!it || it.audioMix != nil) return;
                           NSError *e = nil;
                           if ([asset statusOfValueForKey:@"tracks" error:&e] != AVKeyValueStatusLoaded) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                           AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
#pragma clang diagnostic pop
                           if (!track) return;
                           MTAudioProcessingTapCallbacks cb;
                           cb.version = kMTAudioProcessingTapCallbacksVersion_0;
                           cb.clientInfo = (void *)(uintptr_t)key;
                           cb.init = tapInit;
                           cb.finalize = tapFinalize;
                           cb.prepare = tapPrepare;
                           cb.unprepare = tapUnprepare;
                           cb.process = tapProcess;
                           MTAudioProcessingTapRef tap = NULL;
                           OSStatus st = MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tap);
                           if (st != noErr || tap == NULL) return;
                           AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
                           params.audioTapProcessor = tap;
                           CFRelease(tap);
                           AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
                           mix.inputParameters = @[ params ];
                           it.audioMix = mix;
                         });
                       }];
}

// Swizzled AVQueuePlayer / AVPlayer methods: attach the tap, then carry on.
static IMP origInsert = NULL;
static IMP origReplace = NULL;
static IMP origInitWithItem = NULL;

static void byteInsert(id self, SEL _cmd, AVPlayerItem *item, AVPlayerItem *after) {
  attachTap(item);
  ((void (*)(id, SEL, AVPlayerItem *, AVPlayerItem *))origInsert)(self, _cmd, item, after);
}

static void byteReplace(id self, SEL _cmd, AVPlayerItem *item) {
  attachTap(item);
  ((void (*)(id, SEL, AVPlayerItem *))origReplace)(self, _cmd, item);
}

static id byteInitWithItem(id self, SEL _cmd, AVPlayerItem *item) {
  attachTap(item);
  return ((id(*)(id, SEL, AVPlayerItem *))origInitWithItem)(self, _cmd, item);
}

@implementation ByteEQ

+ (void)install {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    Method m1 = class_getInstanceMethod([AVQueuePlayer class], @selector(insertItem:afterItem:));
    if (m1) origInsert = method_setImplementation(m1, (IMP)byteInsert);
    Method m2 = class_getInstanceMethod([AVPlayer class], @selector(replaceCurrentItemWithPlayerItem:));
    if (m2) origReplace = method_setImplementation(m2, (IMP)byteReplace);
    Method m3 = class_getInstanceMethod([AVPlayer class], @selector(initWithPlayerItem:));
    if (m3) origInitWithItem = method_setImplementation(m3, (IMP)byteInitWithItem);
  });
}

+ (void)setEnabled:(BOOL)enabled frequencies:(NSArray<NSNumber *> *)freqs gains:(NSArray<NSNumber *> *)gains {
  int n = (int)MIN(MIN(freqs.count, gains.count), BYTE_EQ_MAX_BANDS);
  for (int i = 0; i < n; i++) {
    gFreq[i] = freqs[i].floatValue;
    gGain[i] = fmaxf(-15.0f, fminf(15.0f, gains[i].floatValue));
  }
  atomic_store(&gBands, n);
  atomic_store(&gEnabled, enabled ? 1 : 0);
  atomic_fetch_add(&gVersion, 1);
}

+ (void)setLowCut:(NSString *)fileKey amount:(float)amount {
  uint64_t key = byteKeyFor(fileKey);
  if (key == 0) return;
  int milli = (int)lroundf(fmaxf(0.0f, fminf(1.0f, amount)) * 1000.0f);
  int freeSlot = -1;
  for (int i = 0; i < BYTE_CUT_SLOTS; i++) {
    uint64_t k = atomic_load(&gCutKey[i]);
    if (k == key) {
      atomic_store(&gCutMilli[i], milli);
      if (milli == 0) atomic_store(&gCutKey[i], 0);
      return;
    }
    if (k == 0 && freeSlot < 0) freeSlot = i;
  }
  if (milli == 0) return;
  if (freeSlot < 0) freeSlot = 0; // all busy: reuse the oldest slot
  atomic_store(&gCutMilli[freeSlot], milli);
  atomic_store(&gCutKey[freeSlot], key);
}

+ (void)setBalance:(float)balance mono:(BOOL)mono {
  atomic_store(&gBalanceMilli, (int)lroundf(fmaxf(-1.0f, fminf(1.0f, balance)) * 1000.0f));
  atomic_store(&gMono, mono ? 1 : 0);
}
@end
