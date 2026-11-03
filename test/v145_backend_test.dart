// Byte © 2026 Apurba Laskar.
//
// 1.4.5: Byte talks to Apurba's own "Byte" project for everything (sign-in,
// sync, Listen together, admin, web proxy).
import 'package:byte/data/listen_together.dart';
import 'package:byte/web/web_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the Byte project is the default server, the key comes from one constant', () {
    expect(Backend.url, 'https://ymnmrxgbjgvtavzyohdp.supabase.co');
    expect(Backend.anonKey, startsWith('sb_publishable_UX9Y8'));
    expect(Backend.publishableKey, Backend.anonKey);
    expect(Backend.url, isNot(contains('qygsgg')));
  });

  test('the web proxy lives in the same project (no build define needed)', () {
    expect(WebProxy.endpoint.toString(), 'https://ymnmrxgbjgvtavzyohdp.supabase.co/functions/v1/byte-proxy');
  });
}
