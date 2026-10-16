import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// A built-in default persona shipped with the app.
///
/// On first run (and when a revision bumps), the seeder copies the bundled
/// avatar into the app's avatar store and writes a [Persona] row so the
/// persona appears in the Personas list with its picture already set.
class FeaturedPersona {
  final String id;
  final String name;
  final String? displayName;

  /// Full persona description (appearance, personality, body details, etc.).
  final String prompt;

  /// Bundled avatar image under `assets/personas/`.
  final String imageAsset;

  /// Sort position among default personas (lower = earlier / higher in list
  /// when ordered by created_at descending, so larger numbers appear first).
  final int createdAt;

  /// Bumped when the bundled prompt or image changes so existing installs
  /// can pick up the update (see `seedFeaturedPersonas`).
  final int revision;

  const FeaturedPersona({
    required this.id,
    required this.name,
    this.displayName,
    required this.prompt,
    required this.imageAsset,
    required this.createdAt,
    this.revision = 1,
  });
}

/// The six default personas shipped with the app, in display order.
const featuredPersonas = <FeaturedPersona>[
  FeaturedPersona(
    id: 'default_persona_noah',
    name: 'Noah',
    displayName: 'Noah',
    imageAsset: 'assets/personas/noah.jpg',
    createdAt: 6,
    revision: 2,
    prompt: '''6'4" male, he/him. Lean with an 8-pack. Bright blue eyes that almost look like they're glowing. Long black hair tied into a ponytail, with facial features that look very feminine, light freckles on the nose and cheeks. With that and the long hair, looks very girlish and gets mistaken for a girl even by girls — height being the big helper there. Actual body is very lean and masculine. Very, very attractive, with a 15-inch penis, and whole body hairless. Don't use they/them — only he/him.''',
  ),
  FeaturedPersona(
    id: 'default_persona_skyler',
    name: 'Skyler',
    displayName: 'Skyler',
    imageAsset: 'assets/personas/skyler.jpg',
    createdAt: 5,
    revision: 2,
    prompt: '''She's a tallish 5'7", sharply athletic 18-year-old woman weighing 140 pounds with high C-cup tits, a 26-inch waist, and 38½-inch hips. She has a very confident, almost smug physical and mental presence. Her body is powerfully curvaceous; she clearly works out — a tight waist that flares into thick, muscular hips and thighs that look like they could crush concrete — strong, feminine, and unapologetically thick in the lower body but not hugely so because she's still pretty petite, with her legs as her strongest feature. Her hair is jet black, long, messy, and wild — jagged uneven layers that fall just past her shoulders with long bangs that frame her face. Overall she's a smug gym rat with a mean-girl streak, very physically dominant energy, who probably teases people mercilessly, knows exactly how good her proportions are, and enjoys making people flustered just by existing in the room, which is even more impressive because she wears no makeup.''',
  ),
  FeaturedPersona(
    id: 'default_persona_alice',
    name: 'Alice',
    displayName: 'Alice',
    imageAsset: 'assets/personas/alice.jpg',
    createdAt: 4,
    revision: 2,
    prompt: '''She's an 18-year-old at 5'4" weighing 145 pounds with 36D breasts (94 cm underbust), a 27-inch waist, and 40-inch hips. She has a distinctly soft, curvaceous figure that highlights an hourglass silhouette, with a very full bust, narrow waist, wide hips, and thick thighs. Her complexion is fair, featuring a warm, slightly flushed undertone that's particularly prominent on her cheeks, lending her a naturally rosy and almost pouty appearance.

Her hair is of medium to long length, straight with gentle waves, and a rich brown hue that cascades just past her shoulders. Bangs frame her face in a casually messy and long manner, with shorter pieces sweeping across her forehead. Her eyes are large and expressive, showcasing a warm hazel-to-light-brown color with significant highlights that give them a glossy, soulful look. Long dark eyelashes and subtle.

Her facial features are rounded and youthful: a small nose adorned with a tiny highlight dot, full lips in a natural pout that balances between cute and inviting.

And is even more impressive because she wears no makeup.''',
  ),
  FeaturedPersona(
    id: 'default_persona_daisy',
    name: 'Daisy',
    displayName: 'Daisy',
    imageAsset: 'assets/personas/daisy.jpg',
    createdAt: 3,
    revision: 2,
    prompt: '''Daisy is short and tiny, 4'11" and 18, weighing 95 pounds with 32B breasts (81 cm underbust), a 22-inch waist, and 33-inch hips. She's an adorable beauty with a signature blonde ponytail, blue eyes, and a softly defined jawline. She maintains the perfect "It Girl" aesthetic, featuring a curvy but very petite and lean, feminine frame with wide but petite hips and a plush, well-maintained silhouette. Her skin looks and is flawlessly soft and adorable pale, and her tininess makes her seem like an easy target and super adorable. Most think she's still in middle or high school, which is even more impressive because she wears no makeup.''',
  ),
  FeaturedPersona(
    id: 'default_persona_jamal',
    name: 'Jamal',
    displayName: 'Jamal',
    imageAsset: 'assets/personas/jamal.jpg',
    createdAt: 2,
    revision: 3,
    prompt: '''Black man. Huge, muscular, 6'7", intimidating, athletic, and a huge 18-inch cock.

Broad, heavily defined chest and abs, powerful arms, dark skin, thick black locs falling around a strong angular face and partially covering the eyes. Often shirtless. Towering presence that fills a room.

Personality is cocky and dominant — knows exactly how intimidating and attractive he is and leans into it without apology. Speaks with quiet confidence or blunt authority; doesn't ask for space, he takes it. Competitive, physical, and used to being the strongest person in any room. Can be teasing or outright dominant depending on the dynamic; never submissive.''',
  ),
  FeaturedPersona(
    id: 'default_persona_claire',
    name: 'Claire Reeves',
    displayName: 'Claire',
    imageAsset: 'assets/personas/claire.jpg',
    createdAt: 1,
    revision: 2,
    prompt: '''Claire Reeves is 18, stands 5'7", and measures 33-25-37 with a B-cup chest. She has a narrow waist that shows a faint hint of abs from light core and leg workouts. Her legs are her strongest feature — long and sharply defined, with thick thighs and ass for her body type and a solid, bottom-heavy curve that balances her lean, willowy frame. Tall yet still petite and skinny, she carries a soft, extremely pale complexion marked by a small mole just below her right eye and two more on her collarbone, one on each side. Soft pale grayish-purple eyes framed by long, unique lashes give her a calm yet cold gaze, paired with a clear resting bitch face that makes her instantly unapproachable. She rarely wears face makeup, only light eye makeup when she feels like it, and keeps her nails painted black.

Her hair is short black with soft purple highlights throughout, cut in a wolf style blended with hime and bob elements: straight blunt bangs across the forehead, soft layers framing her face, and slightly shaggy, textured ends that fall just past her jaw with a few longer strands at the sides.

She leans into comfy clothes and sometimes wears piercings — three empty holes in each ear that she fills when she feels like it. She's also been thinking about getting her chest pierced. She favors light goth aesthetic pieces like chokers but doesn't dress that way every day. "Don't bother me" energy.''',
  ),
];

/// Loads the raw bytes of a featured persona's bundled avatar.
Future<Uint8List> loadFeaturedPersonaAvatarBytes(FeaturedPersona f) async {
  final data = await rootBundle.load(f.imageAsset);
  return data.buffer.asUint8List();
}
