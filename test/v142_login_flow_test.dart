// Byte © 2026 Apurba Laskar
import 'package:byte/data/service_library.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte 1.4.2 (Apurba, Nov 3): "Amazon Music login — it only showed the
// login, after that nothing happened." The log-in page now always moves on.
void main() {
  test('Amazon session cookie (HttpOnly ones too, read on the phone) means signed in', () {
    expect(hasSessionCookie(LibService.amazon, 'session-id=262-1; ubid-acbin=123; x-acbin="abc"; at-acbin=Atza|xyz; sess-at-acbin="q"'), isTrue);
    expect(hasSessionCookie(LibService.amazon, 'session-id=262-1; ubid-acbin=123; i18n-prefs=INR'), isFalse, reason: 'anonymous visitor cookies only');
    expect(hasSessionCookie(LibService.amazon, 'session-id=1; at-main=Atza|1'), isTrue, reason: 'amazon.com');
    expect(hasSessionCookie(LibService.deezer, 'dzr_uniq_id=1; arl=abc'), isTrue);
    expect(hasSessionCookie(LibService.soundcloud, 'sc_anonymous_id=1'), isFalse);
    expect(hasSessionCookie(LibService.gaana, 'x=1'), isNull, reason: 'no cookie check: the page check decides');
    expect(sessionCookieUrl(LibService.amazon), 'https://www.amazon.in');
    expect(sessionCookieUrl(LibService.amazon, region: 'US'), 'https://www.amazon.com');
  });

  test('signed in on amazon.in but left on its account page → Byte opens the library itself', () {
    expect(nextLoginStep(onService: false, cookie: true, force: false), LoginNext.openLibrary);
    // still typing the password: wait quietly
    expect(nextLoginStep(onService: false, cookie: false, force: false), LoginNext.wait);
    // "I'm logged in" always does something
    expect(nextLoginStep(onService: false, cookie: false, force: true), LoginNext.openLibrary);
    expect(nextLoginStep(onService: false, cookie: false, force: true, afterOpening: true), LoginNext.stillSigningIn);
    expect(nextLoginStep(onService: false, cookie: false, force: false, afterOpening: true), LoginNext.wait);
  });

  test('on the music app: read when the cookie or the page says signed in, or on "I\'m logged in"', () {
    expect(nextLoginStep(onService: true, cookie: true, force: false), LoginNext.read);
    expect(nextLoginStep(onService: true, cookie: null, probe: true, force: false), LoginNext.read);
    expect(nextLoginStep(onService: true, cookie: false, probe: false, force: false), LoginNext.wait);
    expect(nextLoginStep(onService: true, cookie: false, probe: false, force: true), LoginNext.read);
  });

  test('Amazon log-in returns to its library page; the page check is the library path', () {
    final spec = libSpec(LibService.amazon);
    expect(spec.loginUrl, contains('openid.return_to=https%3A%2F%2Fmusic.amazon.in%2Fmy%2Fplaylists'));
    expect(spec.readUrl, 'https://music.amazon.in/my/playlists');
    expect(signedInProbe(LibService.amazon), contains('/my/'));
  });
}
