import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/llm/model_check_service.dart';
import '../../core/llm/model_probe.dart';
import '../../core/models/api_config.dart';
import 'api_list_provider.dart';

/// Checks every saved connection: what context the model really runs with,
/// the sampling values its author recommends (with a one-tap apply), and a
/// short set of roleplay tests that show how well it receives the character
/// card, the memory / summary and the prompt layout.
class ModelCheckScreen extends ConsumerStatefulWidget {
  const ModelCheckScreen({super.key});

  @override
  ConsumerState<ModelCheckScreen> createState() => _ModelCheckScreenState();
}

class _ModelCheckScreenState extends ConsumerState<ModelCheckScreen> {
  final Set<String> _selected = {};
  final Map<String, ModelProbeResult> _probes = {};
  final Map<String, ModelCheckReport> _reports = {};
  final Set<String> _busy = {};
  bool _running = false;

  Future<void> _probe(ApiConfig c) async {
    setState(() => _busy.add(c.id));
    final result = await ModelProbe().probe(c);
    if (!mounted) return;
    setState(() {
      _probes[c.id] = result;
      _busy.remove(c.id);
    });
  }

  Future<void> _check(ApiConfig c) async {
    setState(() => _busy.add(c.id));
    final report = await const ModelCheckService().run(c);
    if (!mounted) return;
    setState(() {
      _reports[c.id] = report;
      _busy.remove(c.id);
    });
  }

  Future<void> _runSelected(List<ApiConfig> all) async {
    setState(() => _running = true);
    for (final c in all.where((c) => _selected.contains(c.id))) {
      if (!mounted) return;
      await _probe(c);
      await _check(c);
    }
    if (mounted) setState(() => _running = false);
  }

  Future<void> _apply(ApiConfig c, ModelProbeResult p) async {
    final next = c.copyWith(
      contextSize: p.recommendedContext ?? c.contextSize,
      temperature: p.temperature ?? c.temperature,
      topP: p.topP ?? c.topP,
      topK: p.topK ?? c.topK,
      // Sampling values only take effect when they are sent.
      omitTemperature: p.temperature != null ? false : c.omitTemperature,
      omitTopP: p.topP != null ? false : c.omitTopP,
      omitTopK: p.topK != null ? false : c.omitTopK,
    );
    await ref.read(apiListProvider.notifier).put(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Applied to "${c.name}".')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final configs = ref.watch(apiListProvider).value ?? const <ApiConfig>[];
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Model check')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Pick the connections to test. Each one is asked what context it '
            'really runs with, then given a few short roleplay tests with '
            'made-up facts: the character card, memory and summary recall, '
            'recall deep in a longer chat, prompt layout and staying in '
            'character. Each test is a real request, so a local model may need '
            'a minute to load.',
            style: TextStyle(color: cs.onSurfaceVariant, height: 1.4),
          ),
          const SizedBox(height: 12),
          if (configs.isEmpty) const Text('No saved connections yet.'),
          for (final c in configs) _card(c, cs),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running || _selected.isEmpty
                ? null
                : () => _runSelected(configs),
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.fact_check_outlined),
            label: Text(
              _running ? 'Checking...' : 'Check ${_selected.length} selected',
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(ApiConfig c, ColorScheme cs) {
    final probe = _probes[c.id];
    final report = _reports[c.id];
    final busy = _busy.contains(c.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: _selected.contains(c.id),
                  onChanged: (v) => setState(() {
                    v == true ? _selected.add(c.id) : _selected.remove(c.id);
                  }),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        c.name.isEmpty ? c.id : c.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        c.model.isEmpty ? 'no model picked' : c.model,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: busy ? null : () => _probe(c),
                  child: const Text('Context & settings'),
                ),
                TextButton(
                  onPressed: busy ? null : () => _check(c),
                  child: const Text('Run tests'),
                ),
              ],
            ),
            if (probe != null) _probeView(c, probe, cs),
            if (report != null) _reportView(report, cs),
          ],
        ),
      ),
    );
  }

  Widget _probeView(ApiConfig c, ModelProbeResult p, ColorScheme cs) {
    if (p.error != null) {
      return Text(p.error!, style: TextStyle(color: cs.error));
    }
    String n(num? v) => v == null ? 'not reported' : '$v';
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Max context: ${n(p.maxContext)}'),
          Text('Running with: ${n(p.loadedContext)}'),
          Text(
            'Suggested: temperature ${n(p.temperature)}, top_p ${n(p.topP)}, '
            'top_k ${n(p.topK)}',
          ),
          Text('Glaze is currently set to context ${c.contextSize}.'),
          if (p.supportsThinking == true)
            const Text('This model can think (reasoning).'),
          for (final note in p.notes)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(note, style: TextStyle(color: cs.tertiary)),
            ),
          if (p.found)
            TextButton(
              onPressed: () => _apply(c, p),
              child: const Text('Apply context & settings'),
            ),
        ],
      ),
    );
  }

  Widget _reportView(ModelCheckReport r, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${r.verdict} - ${r.overall}/100',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          ),
          for (final i in r.items)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i.name}: ${i.score == null ? 'could not run' : '${(i.score! * 100).round()}%'}',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    i.detail,
                    style: TextStyle(fontSize: 12.5, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
