import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/catalog/services/crushon_description.dart';
import 'package:glaze_flutter/features/catalog/services/crushon_provider.dart'
    show crushonFavoritesSortKey;
import 'package:glaze_flutter/features/catalog/services/crushon_session.dart';

void main() {
  const id = '3d54820b-374c-44d2-a0c0-f10435d21b96';

  group('crushonCharacterId', () {
    test('accepts a bare id', () => expect(crushonCharacterId(id), id));
    test('accepts /character/<id>',
        () => expect(crushonCharacterId('/character/$id'), id));
    test('accepts the pasted share link', () {
      expect(
        crushonCharacterId(
          'https://crushon.ai/en/character/$id/details?shared=true',
        ),
        id,
      );
    });
  });

  group('isCrushOnReaderAllowedUrl (hidden browser never leaves the site)', () {
    bool ok(String u) => isCrushOnReaderAllowedUrl(Uri.parse(u));
    test('site, image CDN and Cloudflare are allowed', () {
      expect(ok('https://crushon.ai/en/character/$id/details'), isTrue);
      expect(ok('https://www.crushon.ai/'), isTrue);
      expect(ok('https://img.cocdn.co/_image/optimize/x'), isTrue);
      expect(ok('https://challenges.cloudflare.com/turnstile'), isTrue);
      expect(ok('about:blank'), isTrue);
    });
    test('social links and app schemes are refused', () {
      expect(ok('https://www.reddit.com/r/CrushOn/'), isFalse);
      expect(ok('https://discord.gg/abc'), isFalse);
      expect(ok('https://x.com/crushon'), isFalse);
      expect(ok('https://t.me/crushon'), isFalse);
      expect(ok('reddit://r/CrushOn'), isFalse);
      expect(ok('mailto:a@b.c'), isFalse);
    });
  });

  group('isCrushOnSocialPromoHost (sign-in sheet)', () {
    bool social(String u) => isCrushOnSocialPromoHost(Uri.parse(u));
    test('blocks community hosts', () {
      expect(social('https://www.reddit.com/r/x'), isTrue);
      expect(social('https://old.reddit.com/r/x'), isTrue);
      expect(social('https://redd.it/abc'), isTrue);
    });
    test('does not block sign-in providers', () {
      expect(social('https://accounts.google.com/o/oauth2'), isFalse);
      expect(social('https://discord.com/oauth2/authorize'), isFalse);
      expect(social('https://x.com/i/oauth2/authorize'), isFalse);
      expect(social('https://www.facebook.com/dialog/oauth'), isFalse);
      expect(social('https://crushon.ai/'), isFalse);
    });
  });

  group('crushonLooksLikeNotFound', () {
    test('site 404 art + text', () {
      expect(
        crushonLooksLikeNotFound(
          '<img alt="404 Page Not Found" src="x.png">'
          "<p>Sorry, I can't find the page. Please go back to the previous page.</p>",
        ),
        isTrue,
      );
    });
    test('a real description is kept', () {
      expect(
        crushonLooksLikeNotFound(
          "[Sandbox] Five years ago, you disappeared. Now, you're back.",
        ),
        isFalse,
      );
    });
    test('a long description that mentions a missing page is kept', () {
      expect(
        crushonLooksLikeNotFound('page not found ${'lorem ipsum ' * 120}'),
        isFalse,
      );
    });
  });

  group('crushonIsGenericSiteBlurb', () {
    test('detects the meta-tag marketing text', () {
      expect(
        crushonIsGenericSiteBlurb(
          'An NSFW AI private space exclusive to you and fantasy AI characters.',
        ),
        isTrue,
      );
      expect(crushonIsGenericSiteBlurb('Five years ago, you disappeared.'),
          isFalse);
    });
  });

  group('crushonFavoritesSortKey', () {
    test('Popular stays Popular', () {
      expect(crushonFavoritesSortKey('popular'), 'popular');
      expect(crushonFavoritesSortKey('most_popular'), 'popular');
    });
    test('everything else is the site default, Latest', () {
      for (final s in ['new', 'latest', 'trending', 'daily_ranking', 'recent_hits', '']) {
        expect(crushonFavoritesSortKey(s), 'new', reason: s);
      }
    });
  });
}
