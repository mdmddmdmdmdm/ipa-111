/// Pure helpers that work out a model's maximum context from what a provider's
/// model list says, or (last resort) from the model's name.

int? _asInt(Object? v) {
  if (v is int) return v > 0 ? v : null;
  if (v is num) return v > 0 ? v.toInt() : null;
  if (v is String) {
    final n = int.tryParse(v.trim());
    return (n != null && n > 0) ? n : null;
  }
  return null;
}

Object? _dig(Map m, List<String> path) {
  Object? cur = m;
  for (final k in path) {
    if (cur is Map && cur.containsKey(k)) {
      cur = cur[k];
    } else {
      return null;
    }
  }
  return cur;
}

/// Lowercase id without a leading `models/`.
String normalizeModelId(String id) {
  var s = id.trim().toLowerCase();
  if (s.startsWith('models/')) s = s.substring('models/'.length);
  return s;
}

/// The model entry for [model] in a provider's model list. Exact id first, then
/// the same id without an OpenRouter-style `:free` suffix, then the same name
/// without its `org/` prefix.
Map? findModelEntry(List<Map<dynamic, dynamic>> models, String model) {
  final want = normalizeModelId(model);
  String idOf(Map m) => normalizeModelId('${m['id'] ?? m['name'] ?? ''}');
  String noTag(String s) => s.split(':').first;
  String noOrg(String s) => s.contains('/') ? s.split('/').last : s;
  for (final m in models) {
    if (idOf(m) == want) return m;
  }
  for (final m in models) {
    if (noTag(idOf(m)) == noTag(want)) return m;
  }
  for (final m in models) {
    if (noOrg(noTag(idOf(m))) == noOrg(noTag(want))) return m;
  }
  return null;
}

/// The maximum context a model-list entry reports, whatever the provider calls
/// it: OpenRouter/Together `context_length`, Gemini `inputTokenLimit`, Anthropic
/// `max_input_tokens`, Mistral `max_context_length`, Groq `context_window`,
/// vLLM `max_model_len`, llama.cpp `meta.n_ctx_train`, LM Studio
/// `max_context_length`, GitHub/Copilot `capabilities.limits...`.
int? contextFromModelEntry(Map m) {
  const top = [
    'max_input_tokens',
    'inputTokenLimit',
    'input_token_limit',
    'max_context_length',
    'context_length',
    'context_window',
    'contextWindow',
    'max_model_len',
    'max_prompt_tokens',
    'n_ctx',
  ];
  for (final k in top) {
    final v = _asInt(m[k]);
    if (v != null) return v;
  }
  for (final path in const [
    ['top_provider', 'context_length'],
    ['meta', 'n_ctx_train'],
    ['capabilities', 'limits', 'max_context_window_tokens'],
    ['limits', 'max_context_window_tokens'],
    ['capabilities', 'limits', 'max_prompt_tokens'],
  ]) {
    final v = _asInt(_dig(m, path));
    if (v != null) return v;
  }
  return null;
}

/// Rough maximum context for well-known model families, used ONLY when neither
/// the server nor the provider's model list says. Numbers are the families'
/// published windows and can be out of date; callers must label them as an
/// estimate.
int? knownModelContext(String model) {
  final n = normalizeModelId(model);
  final base = n.contains('/') ? n.split('/').last : n;
  bool has(String re) => RegExp(re).hasMatch(base);
  if (has(r'gpt-4\.1')) return 1047576;
  if (has(r'gpt-5')) return 400000;
  if (has(r'gpt-4o|gpt-4-turbo|gpt-4\.5')) return 128000;
  if (has(r'(^|[^a-z])o[134](-|$)')) return 200000;
  if (has(r'gpt-4-32k')) return 32768;
  if (has(r'gpt-4(-0|$)')) return 8192;
  if (has(r'gpt-3\.5')) return 16385;
  if (has(r'claude')) return 200000;
  if (has(r'gemini-1\.5-pro')) return 2097152;
  if (has(r'gemini')) return 1048576;
  if (has(r'deepseek')) return 128000;
  if (has(r'mistral-large|mistral-nemo|mistral-medium')) return 128000;
  if (has(r'llama-?3\.[123]')) return 131072;
  return null;
}
