import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/repositories/persona_repo.dart';
import '../models/persona.dart';
import '../state/db_provider.dart';
import '../state/shared_prefs_provider.dart';
import 'featured_personas.dart';
import 'image_storage_service.dart';

const _featuredPersonasSeededKey = 'featuredPersonasSeeded_v1';

/// Per-persona revision last written by the seeder, so a shipped update to a
/// bundled persona can be told apart from one the user has kept or deleted.
String _personaRevisionKey(String id) => 'featuredPersonaRev_$id';

/// Seeds the six default personas (Noah, Skyler, Alice, Daisy, Jamal, Claire)
/// with their bundled avatars.
///
/// Same rules as preset seeding: a first run creates every persona; later runs
/// leave a deleted persona deleted. A persona still in the library is refreshed
/// when its bundled [FeaturedPersona.revision] is newer than the one the seeder
/// last wrote — the way a shipped update reaches existing installs.
Future<void> seedFeaturedPersonas(WidgetRef ref) async {
  final prefs = await ref.read(sharedPreferencesProvider.future);
  final firstRun = prefs.getBool(_featuredPersonasSeededKey) != true;
  final repo = ref.read(personaRepoProvider);
  final imageStorage = await ref.read(imageStorageProvider.future);

  for (final f in featuredPersonas) {
    final revisionKey = _personaRevisionKey(f.id);
    final existing = await repo.getById(f.id);
    if (existing == null) {
      if (firstRun) {
        await _writePersona(f, repo, imageStorage);
        await prefs.setInt(revisionKey, f.revision);
      }
      continue;
    }
    final seededRevision = prefs.getInt(revisionKey) ?? 1;
    if (f.revision > seededRevision) {
      await _writePersona(
        f,
        repo,
        imageStorage,
        keepCreatedAt: existing.createdAt,
      );
      await prefs.setInt(revisionKey, f.revision);
    }
  }

  await prefs.setBool(_featuredPersonasSeededKey, true);
}

Future<void> _writePersona(
  FeaturedPersona f,
  PersonaRepo repo,
  ImageStorageService imageStorage, {
  int? keepCreatedAt,
}) async {
  final bytes = await loadFeaturedPersonaAvatarBytes(f);
  // Stable avatar id so re-seeding does not orphan old files.
  final avatarPath = await imageStorage.saveAvatar('persona_${f.id}', bytes);
  final persona = Persona(
    id: f.id,
    name: f.name,
    displayName: f.displayName,
    prompt: f.prompt,
    avatarPath: avatarPath,
    createdAt: keepCreatedAt ?? f.createdAt,
  );
  await repo.put(persona);
}
