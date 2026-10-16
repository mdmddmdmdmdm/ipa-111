import '../models/api_config.dart';
import 'aux_llm_client.dart';

/// One scored check.
class ModelCheckItem {
  final String name;

  /// 0.0 - 1.0, or null when the check could not run.
  final double? score;
  final String detail;
  final int millis;

  const ModelCheckItem(this.name, this.score, this.detail, this.millis);
}

class ModelCheckReport {
  final String configName;
  final String model;
  final List<ModelCheckItem> items;

  const ModelCheckReport(this.configName, this.model, this.items);

  /// Mean of the checks that ran, 0 - 100.
  int get overall {
    final scored = [
      for (final i in items)
        if (i.score != null) i.score!,
    ];
    if (scored.isEmpty) return 0;
    return (scored.reduce((a, b) => a + b) / scored.length * 100).round();
  }

  String get verdict {
    final o = overall;
    if (items.isNotEmpty && items.first.score == null) return 'Not reachable';
    if (o >= 85) return 'Excellent';
    if (o >= 65) return 'Good';
    if (o >= 40) return 'Weak';
    return 'Poor';
  }
}

/// Runs a fixed set of small roleplay checks against one connection and scores
/// them. Every fact in the checks is made up, so a correct answer can only come
/// from the prompt, never from the model's training data.
class ModelCheckService {
  final AuxLlmClient _llm;

  const ModelCheckService({AuxLlmClient llm = const AuxLlmClient()})
    : _llm = llm;

  static const _card =
      'You are Mirela Voss, a lighthouse keeper on Cape Alder. Amber eyes, '
      'dry humour, hates cilantro. Her grey cat is named Biscuit. Stay in '
      "character and never speak for the user.";

  static const _memory =
      '[Memory of earlier events]\n'
      '- The user\'s brother is called Teodor.\n'
      '- Mirela and the user agreed to meet at the clock tower at nine in the '
      'evening.\n'
      '- The user is allergic to peanuts.';

  Future<ModelCheckReport> run(ApiConfig config) async {
    final items = <ModelCheckItem>[];
    final aux = AuxApiConfig(
      endpoint: config.endpoint,
      apiKey: config.apiKey,
      model: config.model,
      protocol: config.protocol,
      useResponsesApi: config.useResponsesApi,
      omitTemperature: config.omitTemperature,
      extraRequestParameters: config.extraRequestParameters,
    );

    Future<({String? text, int ms, String? error})> ask(
      List<Map<String, String>> messages,
    ) async {
      final sw = Stopwatch()..start();
      try {
        final text = await _llm.callOnce(
          config: aux,
          messages: messages,
          maxTokens: config.maxTokens > 1500 ? config.maxTokens : 1500,
          temperature: 0.2,
          timeoutMs: config.firstChunkTimeoutMs > 180000
              ? config.firstChunkTimeoutMs
              : 180000,
        );
        return (text: _clean(text), ms: sw.elapsedMilliseconds, error: null);
      } catch (e) {
        return (text: null, ms: sw.elapsedMilliseconds, error: '$e');
      }
    }

    ModelCheckItem scoreKeywords(
      String name,
      ({String? text, int ms, String? error}) r,
      List<List<String>> wanted,
    ) {
      if (r.error != null) {
        return ModelCheckItem(name, null, _short(r.error!), r.ms);
      }
      final text = (r.text ?? '').toLowerCase();
      if (text.trim().isEmpty) {
        return ModelCheckItem(
          name,
          0,
          'Empty answer (a thinking model may have used the whole token '
          'budget - raise Max tokens or turn its reasoning off).',
          r.ms,
        );
      }
      var hit = 0;
      final missing = <String>[];
      for (final alts in wanted) {
        if (alts.any(text.contains)) {
          hit++;
        } else {
          missing.add(alts.first);
        }
      }
      final detail = missing.isEmpty
          ? 'All $hit facts used.'
          : '$hit/${wanted.length} facts. Missed: ${missing.join(', ')}.';
      return ModelCheckItem(name, hit / wanted.length, detail, r.ms);
    }

    // 1. Reachability and speed.
    final ping = await ask([
      {'role': 'user', 'content': 'Reply with the single word: ready'},
    ]);
    if (ping.error != null || (ping.text ?? '').trim().isEmpty) {
      items.add(
        ModelCheckItem(
          'Connection',
          null,
          ping.error != null
              ? _short(ping.error!)
              : 'Connected but the model returned nothing.',
          ping.ms,
        ),
      );
      return ModelCheckReport(config.name, config.model, items);
    }
    items.add(
      ModelCheckItem(
        'Connection',
        1,
        'Answered in ${(ping.ms / 1000).toStringAsFixed(1)} s '
        '(includes model load).',
        ping.ms,
      ),
    );

    // 2. Character card.
    items.add(
      scoreKeywords(
        'Character details',
        await ask([
          {'role': 'system', 'content': _card},
          {
            'role': 'user',
            'content':
                'Quick questions, answer plainly: what is your name, what '
                'colour are your eyes, what is your cat called, and what '
                'food do you hate?',
          },
        ]),
        [
          ['mirela'],
          ['amber'],
          ['biscuit'],
          ['cilantro', 'coriander'],
        ],
      ),
    );

    // 3. Memory / summary delivered as a system block.
    items.add(
      scoreKeywords(
        'Memory recall',
        await ask([
          {'role': 'system', 'content': '$_card\n\n$_memory'},
          {
            'role': 'user',
            'content':
                'Remind me: what is my brother called, where and when are we '
                'meeting, and what am I allergic to?',
          },
        ]),
        [
          ['teodor'],
          ['clock tower'],
          ['nine', '9'],
          ['peanut'],
        ],
      ),
    );

    // 4. Memory that sits far back in a longer conversation.
    final filler = <Map<String, String>>[];
    const lines = [
      ['Is the lamp lit tonight?', 'It is. The storm is rolling in.'],
      ['Do you ever get bored here?', 'Rarely. The sea is never the same twice.'],
      ['What do you eat out here?', 'Tinned fish and whatever the boat brings.'],
      ['Is the climb to the top hard?', 'Two hundred steps. You get used to it.'],
      ['Any ships out there?', 'Just one fishing boat, heading home.'],
      ['Does the wind ever stop?', 'Only in the dead of winter.'],
    ];
    for (final l in lines) {
      filler.add({'role': 'user', 'content': l[0]});
      filler.add({'role': 'assistant', 'content': l[1]});
    }
    items.add(
      scoreKeywords(
        'Memory in a longer chat',
        await ask([
          {'role': 'system', 'content': '$_card\n\n$_memory'},
          ...filler,
          {
            'role': 'user',
            'content': 'Before I forget - who is Teodor, and what must you '
                'never put in my food?',
          },
        ]),
        [
          ['brother'],
          ['peanut'],
        ],
      ),
    );

    // 5. Does the model's chat template accept Glaze's normal layout (a system
    // message after the conversation has started)?
    final layout = await ask([
      {'role': 'system', 'content': _card},
      {'role': 'user', 'content': 'Hello there.'},
      {'role': 'assistant', 'content': 'Evening. Lamp is lit.'},
      {'role': 'user', 'content': 'Good. What is your name?'},
      {'role': 'system', 'content': 'Keep every reply under two sentences.'},
    ]);
    if (layout.error != null) {
      items.add(
        ModelCheckItem(
          'Prompt layout',
          0.5,
          'Rejected a system message mid-chat. Set Prompt post-processing to '
          '"Strict" for this connection. (${_short(layout.error!)})',
          layout.ms,
        ),
      );
    } else {
      items.add(
        scoreKeywords('Prompt layout', layout, [
          ['mirela'],
        ]),
      );
    }

    // 6. Staying in character without writing the user's lines.
    final agency = await ask([
      {'role': 'system', 'content': _card},
      {
        'role': 'user',
        'content': 'I walk up the stairs and knock on your door.',
      },
    ]);
    if (agency.error != null) {
      items.add(ModelCheckItem('Roleplay behaviour', null, _short(agency.error!), agency.ms));
    } else {
      final t = (agency.text ?? '').toLowerCase();
      final speaksForUser =
          t.contains('\nuser:') || t.startsWith('user:') || t.contains('"i walk');
      final asAssistant = t.contains('as an ai') || t.contains('language model');
      final ok = t.trim().isNotEmpty && !speaksForUser && !asAssistant;
      items.add(
        ModelCheckItem(
          'Roleplay behaviour',
          ok ? 1 : 0,
          ok
              ? 'Stayed in character and did not write the user\'s lines.'
              : asAssistant
              ? 'Broke character ("as an AI").'
              : speaksForUser
              ? 'Wrote the user\'s part of the scene.'
              : 'Empty answer.',
          agency.ms,
        ),
      );
    }
    return ModelCheckReport(config.name, config.model, items);
  }

  static String _clean(String text) => text
      .replaceAll(RegExp(r'<think(ing)?>[\s\S]*?</think(ing)?>'), '')
      .trim();

  static String _short(String s) => s.length > 220 ? '${s.substring(0, 220)}...' : s;
}
