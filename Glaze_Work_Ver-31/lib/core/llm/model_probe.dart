import 'package:dio/dio.dart';

import '../models/api_config.dart';
import 'model_context_lookup.dart';
import 'transport/transport_factory.dart';

/// What the server told us about a model.
class ModelProbeResult {
  /// Largest context the model was trained for, in tokens.
  final int? maxContext;

  /// Context the server is actually running the model with right now. This is
  /// the number that matters: a prompt longer than it loses its beginning.
  final int? loadedContext;

  /// Sampling values the model's own author recommends (Modelfile / server
  /// defaults), when the server reports them.
  final double? temperature;
  final double? topP;
  final int? topK;
  final double? repeatPenalty;

  /// True when the model reports a thinking capability.
  final bool? supportsThinking;

  /// Where the numbers came from ("Ollama /api/show", "llama.cpp /props" ...).
  final List<String> sources;

  /// Things worth telling the user.
  final List<String> notes;
  final String? error;

  const ModelProbeResult({
    this.maxContext,
    this.loadedContext,
    this.temperature,
    this.topP,
    this.topK,
    this.repeatPenalty,
    this.supportsThinking,
    this.sources = const [],
    this.notes = const [],
    this.error,
  });

  bool get found => maxContext != null || loadedContext != null;

  /// The context size Glaze should be set to: what the server really runs,
  /// else the model's maximum.
  int? get recommendedContext => loadedContext ?? maxContext;
}

/// Asks a local server (Ollama first, then llama.cpp / vLLM / LM Studio style
/// `/models` metadata) for the model's context length and default sampling.
/// Nothing is guessed: a value that the server does not report stays null.
class ModelProbe {
  final Dio _dio;

  ModelProbe({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              validateStatus: (_) => true,
            ),
          );

  /// `http://host:11434/v1/chat/completions` -> `http://host:11434`.
  static String originOf(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !uri.hasAuthority) return '';
    return '${uri.scheme}://${uri.authority}';
  }

  Future<ModelProbeResult> probe(ApiConfig config) async {
    final origin = originOf(config.endpoint);
    final model = config.model.trim();
    if (origin.isEmpty) {
      return const ModelProbeResult(error: 'Endpoint is not a valid URL.');
    }
    if (model.isEmpty) {
      return const ModelProbeResult(error: 'Pick a model first.');
    }
    final headers = <String, String>{
      if (config.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey.trim()}',
    };

    final ollama = await _ollama(origin, model, headers);
    if (ollama != null && ollama.found) return ollama;

    // Local servers first (they report what is actually loaded), then the
    // provider's own model list over its own protocol and auth (OpenRouter,
    // Gemini, Anthropic, Mistral, Groq...), then LM Studio, then a name table.
    final generic = await _generic(origin, config, model, headers);
    final lm = generic.maxContext == null
        ? await _lmStudio(origin, model, headers)
        : null;
    final listed = (generic.maxContext == null && lm?.maxContext == null)
        ? await _fromProviderList(config, model)
        : null;

    final max = generic.maxContext ?? lm?.maxContext ?? listed?.maxContext;
    final loaded = generic.loadedContext ?? lm?.loadedContext;
    final sources = <String>[
      ...?ollama?.sources,
      ...generic.sources,
      ...?lm?.sources,
      ...?listed?.sources,
    ];
    if (max != null || loaded != null) {
      return ModelProbeResult(
        maxContext: max,
        loadedContext: loaded,
        sources: sources,
        notes: [
          if (loaded != null && max != null && loaded < max)
            'The server runs this model with $loaded tokens of context, below '
                'its maximum of $max.',
        ],
      );
    }
    final guess = knownModelContext(model);
    if (guess != null) {
      return ModelProbeResult(
        maxContext: guess,
        sources: const ['Built-in table (estimate)'],
        notes: [
          'The provider did not report a context length. $guess tokens is the '
              'published window for this model family and may be out of date; '
              'check the provider\'s model page.',
        ],
      );
    }
    return ModelProbeResult(
      sources: sources,
      notes: const [
        'The server did not report a context length and this model is not in '
            'the built-in table. Check it in the provider or server itself '
            '(for Ollama: `ollama show <model>` and `ollama ps`).',
      ],
    );
  }

  /// The provider's own model list, fetched with the connection's protocol so
  /// the right auth is used, searched for this model.
  Future<ModelProbeResult?> _fromProviderList(
    ApiConfig config,
    String model,
  ) async {
    try {
      final list = await pickChatTransportFor(
        config,
      ).fetchModels(endpoint: config.endpoint, apiKey: config.apiKey);
      final entry = findModelEntry(
        list.cast<Map<dynamic, dynamic>>(),
        model,
      );
      if (entry == null) return null;
      final ctx = contextFromModelEntry(entry);
      if (ctx == null) return null;
      return ModelProbeResult(
        maxContext: ctx,
        sources: const ['Provider model list'],
      );
    } catch (_) {
      return null;
    }
  }

  /// LM Studio's native API reports both the model's maximum and the context it
  /// is currently loaded with.
  Future<ModelProbeResult?> _lmStudio(
    String origin,
    String model,
    Map<String, String> headers,
  ) async {
    try {
      final res = await _dio.get<dynamic>(
        '$origin/api/v0/models/${Uri.encodeComponent(model)}',
        options: Options(headers: headers),
      );
      final d = res.data;
      if (res.statusCode != 200 || d is! Map) return null;
      final max = _asInt(d['max_context_length']);
      final loaded = _asInt(d['loaded_context_length']);
      if (max == null && loaded == null) return null;
      return ModelProbeResult(
        maxContext: max,
        loadedContext: loaded,
        sources: const ['LM Studio /api/v0/models'],
      );
    } catch (_) {
      return null;
    }
  }

  Future<ModelProbeResult?> _ollama(
    String origin,
    String model,
    Map<String, String> headers,
  ) async {
    try {
      final show = await _dio.post<dynamic>(
        '$origin/api/show',
        data: {'model': model, 'name': model},
        options: Options(headers: headers),
      );
      final data = show.data;
      if (show.statusCode != 200 || data is! Map) return null;

      int? maxContext;
      final info = data['model_info'];
      if (info is Map) {
        for (final entry in info.entries) {
          if (entry.key.toString().endsWith('.context_length')) {
            maxContext = _asInt(entry.value);
            break;
          }
        }
      }

      double? temperature, topP, repeat;
      int? topK, numCtx;
      final params = data['parameters'];
      if (params is String) {
        for (final line in params.split('\n')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 2) continue;
          final value = parts[1];
          switch (parts[0]) {
            case 'temperature':
              temperature = double.tryParse(value);
            case 'top_p':
              topP = double.tryParse(value);
            case 'top_k':
              topK = int.tryParse(value);
            case 'repeat_penalty':
              repeat = double.tryParse(value);
            case 'num_ctx':
              numCtx = int.tryParse(value);
          }
        }
      }
      final caps = data['capabilities'];
      final thinking = caps is List ? caps.contains('thinking') : null;

      // What is loaded right now (only present while the model is in memory).
      int? loaded;
      try {
        final ps = await _dio.get<dynamic>(
          '$origin/api/ps',
          options: Options(headers: headers),
        );
        final models = ps.data is Map ? (ps.data as Map)['models'] : null;
        if (models is List) {
          for (final m in models) {
            if (m is Map &&
                (m['name'] == model ||
                    m['model'] == model ||
                    '${m['name']}'.split(':').first == model.split(':').first)) {
              loaded = _asInt(m['context_length']);
            }
          }
        }
      } catch (_) {}

      final notes = <String>[];
      final running = loaded ?? numCtx;
      if (running == null) {
        notes.add(
          'The model is not loaded yet and its Modelfile sets no num_ctx, so '
          'Ollama will use its own default (often 4096). Set '
          'OLLAMA_CONTEXT_LENGTH or a Modelfile num_ctx, then send a message '
          'and run this again.',
        );
      } else if (maxContext != null && running < maxContext) {
        notes.add(
          'Ollama runs this model with $running tokens of context, below its '
          'maximum of $maxContext. Anything longer silently loses the start of '
          'the prompt, including the character card.',
        );
      }
      return ModelProbeResult(
        maxContext: maxContext,
        loadedContext: running,
        temperature: temperature,
        topP: topP,
        topK: topK,
        repeatPenalty: repeat,
        supportsThinking: thinking,
        sources: const ['Ollama /api/show'],
        notes: notes,
      );
    } catch (_) {
      return null;
    }
  }

  Future<ModelProbeResult> _generic(
    String origin,
    ApiConfig config,
    String model,
    Map<String, String> headers,
  ) async {
    int? maxContext, loaded;
    final sources = <String>[];
    // llama.cpp: the context the server was started with.
    try {
      final props = await _dio.get<dynamic>(
        '$origin/props',
        options: Options(headers: headers),
      );
      final data = props.data;
      if (props.statusCode == 200 && data is Map) {
        final settings = data['default_generation_settings'];
        if (settings is Map) loaded = _asInt(settings['n_ctx']);
        if (loaded != null) sources.add('llama.cpp /props');
      }
    } catch (_) {}
    // OpenAI-style /models listing with extra metadata.
    for (final url in {
      '${config.endpoint.trim().replaceAll(RegExp(r'/chat/completions/?$'), '').replaceAll(RegExp(r'/+$'), '')}/models',
      '$origin/v1/models',
    }) {
      try {
        final res = await _dio.get<dynamic>(
          url,
          options: Options(headers: headers),
        );
        final list = res.data is Map ? (res.data as Map)['data'] : null;
        if (res.statusCode != 200 || list is! List) continue;
        final entry = findModelEntry(
          list.whereType<Map>().cast<Map<dynamic, dynamic>>().toList(),
          model,
        );
        if (entry != null) maxContext = contextFromModelEntry(entry);
        if (maxContext != null) {
          sources.add('/models');
          break;
        }
      } catch (_) {}
    }
    return ModelProbeResult(
      maxContext: maxContext,
      loadedContext: loaded,
      sources: sources,
    );
  }

  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
