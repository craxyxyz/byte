// © 2026 Apurba Laskar
import 'package:flutter/foundation.dart';

/// Tests flip this to check what the browser version shows.
@visibleForTesting
bool debugPretendWeb = false;

/// True in the browser version of Byte. Rows for things a browser can't do
/// (downloads, a music folder on the phone, USB DAC, lock screen, cast) hide.
bool get onWeb => kIsWeb || debugPretendWeb;
