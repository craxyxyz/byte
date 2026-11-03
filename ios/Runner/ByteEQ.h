// Byte © 2026 Apurba Laskar — equalizer for the iPhone player.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A 10-band equalizer applied to every song the app plays, through an audio
/// processing tap on each AVPlayerItem (attached automatically).
@interface ByteEQ : NSObject
/// Called from Dart: enabled, band centre frequencies (Hz) and gains (dB).
+ (void)setEnabled:(BOOL)enabled frequencies:(NSArray<NSNumber *> *)freqs gains:(NSArray<NSNumber *> *)gains;
/// Automix bass swap: high-pass amount 0..1 for the song whose file name is [fileKey].
+ (void)setLowCut:(NSString *)fileKey amount:(float)amount;
/// Starts attaching the equalizer to player items (call once at launch).
+ (void)install;
@end

NS_ASSUME_NONNULL_END
