import 'package:flutter/material.dart';

import '../../../core/llm/character_field_switches.dart';
import '../../../shared/theme/app_colors.dart';

/// One row per character field that can go to the model: a status dot, the
/// field's name with what is happening to it, and an on/off switch.
///
/// Switch ON means "send this field" (the app adds it even when the active
/// preset leaves its block out). OFF means "never send it". The dot comes from
/// a real test build of the prompt, so it shows what the model would get.
class PromptFieldsPanel extends StatelessWidget {
  final bool Function(CharacterPromptField field) isOn;
  final FieldDeliveryReport? Function(CharacterPromptField field) reportFor;
  final void Function(CharacterPromptField field, bool value) onToggle;
  final VoidCallback onCheck;
  final bool checking;

  const PromptFieldsPanel({
    super.key,
    required this.isOn,
    required this.reportFor,
    required this.onToggle,
    required this.onCheck,
    required this.checking,
  });

  static Color _color(BuildContext context, FieldDelivery? status) =>
      switch (status) {
        FieldDelivery.sending => const Color(0xFF2E9E5B),
        FieldDelivery.missing => const Color(0xFFD64545),
        FieldDelivery.empty => const Color(0xFFD9A441),
        FieldDelivery.off => context.cs.outline,
        FieldDelivery.unchecked || null => context.cs.outlineVariant,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'On: this field is sent to the model every message, even if the '
            'preset leaves its block out. Off: it is never sent. Turning a '
            'switch on tests it right away.',
            style: TextStyle(
              color: context.cs.onSurfaceVariant,
              fontSize: 13,
              height: 1.45,
            ),
          ),
        ),
        for (final field in CharacterPromptField.values)
          _row(context, field),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: checking ? null : onCheck,
              icon: checking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fact_check_outlined, size: 18),
              label: const Text('Check what is being sent'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, CharacterPromptField field) {
    final report = reportFor(field);
    final on = isOn(field);
    final status = report?.status;
    // The switch is the source of truth for on/off; the report only says how
    // an "on" field fared, and may be one check behind a fresh toggle.
    final detail = !on
        ? 'Off - not sent to the model'
        : (report == null || status == FieldDelivery.off)
        ? 'On - checking...'
        : report.detail;
    final color = _color(context, on ? status : FieldDelivery.off);
    return InkWell(
      onTap: () => onToggle(field, !on),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    field.label,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: TextStyle(fontSize: 12.5, color: color),
                  ),
                ],
              ),
            ),
            Switch.adaptive(value: on, onChanged: (v) => onToggle(field, v)),
          ],
        ),
      ),
    );
  }
}
