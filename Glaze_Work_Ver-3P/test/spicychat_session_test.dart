import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/saved_accounts_provider.dart';
import 'package:glaze_flutter/features/catalog/services/spicychat_session.dart';
import 'package:glaze_flutter/features/catalog/third_party_providers_provider.dart';

void main() {
  const snapshot = SpicyChatSessionSnapshot(
    cookies: [
      SpicyChatCookie(
        name: 'sid',
        value: 'abc',
        origin: 'https://spicychat.ai',
        domain: '.spicychat.ai',
        path: '/',
        expires: 4102444800000,
        secure: true,
        httpOnly: true,
      ),
    ],
    local: {'authToken': 'tok'},
    session: {'tab': '1'},
  );

  test('a session snapshot survives encode and parse', () {
    final parsed = SpicyChatSessionSnapshot.tryParse(snapshot.encode())!;
    expect(parsed.cookies.single.name, 'sid');
    expect(parsed.cookies.single.domain, '.spicychat.ai');
    expect(parsed.cookies.single.httpOnly, isTrue);
    expect(parsed.cookies.single.expires, 4102444800000);
    expect(parsed.local, {'authToken': 'tok'});
    expect(parsed.session, {'tab': '1'});
  });

  test('empty, missing and corrupt snapshots parse to null', () {
    expect(SpicyChatSessionSnapshot.tryParse(null), isNull);
    expect(SpicyChatSessionSnapshot.tryParse(''), isNull);
    expect(SpicyChatSessionSnapshot.tryParse('not json'), isNull);
    expect(SpicyChatSessionSnapshot.tryParse('{"cookies":[]}'), isNull);
  });

  test('a saved credential carries the session next to the sign-in method', () {
    final encoded = SavedCredential(
      email: 'alice@example.com',
      method: 'google',
      session: snapshot.encode(),
    ).encode();
    final back = SavedCredential.tryParse(encoded)!;
    expect(back.email, 'alice@example.com');
    expect(back.method, 'google');
    expect(back.hasSession, isTrue);
    expect(SpicyChatSessionSnapshot.tryParse(back.session), isNotNull);
    // No password was stored, so nothing can be replayed from this entry.
    expect(back.hasPasswordLogin, isFalse);
  });

  test('saved account ids ignore case and surrounding spaces', () {
    expect(
      SavedAccountsNotifier.idFor(
        ThirdPartyProvider.spicychat,
        '  Alice@Example.com ',
      ),
      'spicychat:alice@example.com',
    );
  });
}
