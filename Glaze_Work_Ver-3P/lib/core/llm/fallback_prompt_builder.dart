import '../models/chat_message.dart';
import 'character_field_switches.dart';
import 'context_calculator.dart';
import 'character_prompt_extras.dart';
import 'history_assembler.dart';
import 'macro_engine.dart';
import 'prompt_builder.dart';

PromptResult buildFallbackPrompt(PromptPayload payload) {
  final macroCtx = MacroContext(
    charName: payload.character.name,
    charDescription: payload.character.description,
    charScenario: payload.character.scenario,
    charPersonality: payload.character.personality,
    charMesExample: payload.character.mesExample,
    userName: payload.persona?.name ?? 'User',
    personaPrompt: payload.persona?.prompt,
    charId: payload.character.id,
    sessionId: '',
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
    macroName: payload.character.macroName,
    gameTime: payload.gameTime,
    gameDate: payload.gameDate,
    gameDay: payload.gameDay,
  );

  const systemMessage = PromptMessage(
    role: 'system',
    content: 'You are a helpful assistant.',
  );
  final history = <PromptMessage>[];

  for (final msg in payload.history.where(
    (message) => !message.isHidden && !message.isTyping,
  )) {
    final macroResult = replaceMacros(msg.content, macroCtx);
    history.add(
      PromptMessage(
        role: msg.role,
        content: macroResult.text,
        reasoningContent: msg.reasoning,
        isHistory: true,
        sourceMessageId: msg.id,
        imagePaths: msg.imageHidden ? const [] : msg.attachments,
      ),
    );
  }

  // With no preset there is nothing to pull the character card in, so the
  // model used to get only "You are a helpful assistant." and no character at
  // all. Send the card (and the fields presets never carried) explicitly.
  final extras = CharacterPromptExtras.resolve(payload.character, macroCtx);
  final cardText = _fallbackCharacterCard(payload, macroCtx, extras);
  final cardMessages = <PromptMessage>[
    if (cardText.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: cardText,
        blockId: 'char_card',
        blockName: 'Character',
      ),
  ];
  final postHistoryMessages = <PromptMessage>[
    if (extras.postHistory.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: extras.postHistory,
        blockId: kCharPostHistoryBlockId,
        blockName: 'Chat History Instruction',
      ),
  ];

  final calculator = ContextCalculator(
    contextSize: payload.apiConfig.contextSize,
    maxTokens: payload.apiConfig.maxTokens,
    reasoningHistoryCount: payload.apiConfig.reasoningHistoryCount,
    excludeReasoningFromContextBudget:
        payload.apiConfig.excludeReasoningFromContextBudget,
    historyTrimMode: payload.apiConfig.historyTrimMode,
    historyAnchorId: payload.sessionVars[ChatSessionX.historyAnchorVarKey],
    historyTrimTriggerPercent: payload.apiConfig.historyTrimTriggerPercent,
    historyTrimStepPercent: payload.apiConfig.historyTrimStepPercent,
  );
  final ledgerMessages = <PromptMessage>[
    if (payload.characterKnowledgeContent case final content?
        when content.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: content,
        blockId: 'current_character_state',
      ),
    if (payload.studioSessionStateContent case final content?
        when content.isNotEmpty)
      PromptMessage(
        role: 'system',
        content: content,
        blockId: 'studio_session_state',
      ),
    if (payload.arcContent case final content? when content.isNotEmpty)
      PromptMessage(role: 'system', content: content, blockId: 'arc_state'),
  ];
  final breakdown = calculator.calculate(
    staticBlocks: [
      const StaticBlock(
        id: 'fallback_system',
        content: 'You are a helpful assistant.',
      ),
      for (final message in cardMessages)
        StaticBlock(id: message.blockId ?? 'preset', content: message.content),
      for (final message in ledgerMessages)
        StaticBlock(id: message.blockId ?? 'preset', content: message.content),
      for (final message in postHistoryMessages)
        StaticBlock(id: message.blockId ?? 'preset', content: message.content),
    ],
    historyMessages: history,
  );

  return PromptResult(
    messages: [
      systemMessage,
      ...cardMessages,
      ...ledgerMessages,
      ...insertContinueInstruction(
        breakdown.trimmedHistory,
        payload.continueInstruction,
      ),
      ...postHistoryMessages,
    ],
    breakdown: breakdown,
    sessionVars: payload.sessionVars,
    globalVars: payload.globalVars,
  );
}

/// Plain-text character card for the no-preset fallback. Fields are expanded
/// with the same macros presets use and skipped when blank, so a character with
/// no text produces no message at all.
String _fallbackCharacterCard(
  PromptPayload payload,
  MacroContext macroCtx,
  CharacterPromptExtras extras,
) {
  final character = payload.character;
  String expand(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return '';
    return replaceMacros(text, macroCtx).text.trim();
  }

  final sections = <String>[];
  void add(String? label, String text) {
    if (text.isEmpty) return;
    sections.add(label == null ? text : '$label\n$text');
  }

  add(null, extras.systemPrompt);
  final personaPrompt = expand(payload.persona?.prompt);
  if (personaPrompt.isNotEmpty) {
    add('User: ${payload.persona?.name ?? 'User'}', personaPrompt);
  }
  String field(CharacterPromptField f, String? raw) =>
      characterFieldEnabled(character, f) ? expand(raw) : '';

  add(null, field(CharacterPromptField.description, character.description));
  add(
    'Personality:',
    field(CharacterPromptField.personality, character.personality),
  );
  add('Scenario:', field(CharacterPromptField.scenario, character.scenario));
  add(null, extras.advancedDefinition);
  add(
    'Example dialogue:',
    field(CharacterPromptField.examples, character.mesExample),
  );
  return sections.join('\n\n');
}
