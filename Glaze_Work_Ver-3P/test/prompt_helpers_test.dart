import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_helpers.dart';

void main() {
  group('PromptHelpers user-name accuracy', () {
    test('persists the new setting and remains backward compatible', () {
      const helpers = PromptHelpers(userNameAccuracy: true);
      final restored = PromptHelpers.fromJson(helpers.toJson());
      expect(restored.userNameAccuracy, isTrue);
      expect(PromptHelpers.fromJson({'formatting': true}).userNameAccuracy, isFalse);
    });

    test('adds explicit persona-name guidance only when enabled', () {
      expect(const PromptHelpers().buildText(), isNull);
      final text = const PromptHelpers(userNameAccuracy: true).buildText();
      expect(text, contains('active persona name supplied by the app'));
      expect(text, contains('{{user}}'));
      expect(text, contains('Do not guess'));
    });

    test('counts name accuracy as an active helper', () {
      expect(const PromptHelpers(userNameAccuracy: true).anyActive, isTrue);
    });
  });

  group('PromptHelpers story helpers', () {
    test('stay in character, on story and limited knowledge add text', () {
      const h = PromptHelpers(
        stayInRole: true,
        stayOnStory: true,
        limitedKnowledge: true,
      );
      expect(h.anyActive, isTrue);
      final text = h.buildText()!;
      expect(text, contains('IMMERSION'));
      expect(text, contains('RELEVANCE'));
      expect(text, contains('KNOWLEDGE LIMITS'));
    });

    test('new helpers survive a JSON round trip', () {
      const h = PromptHelpers(stayInRole: true, limitedKnowledge: true);
      final back = PromptHelpers.fromJson(h.toJson());
      expect(back.stayInRole, isTrue);
      expect(back.stayOnStory, isFalse);
      expect(back.limitedKnowledge, isTrue);
    });
  });

  group('PromptHelpers emojis', () {
    test('is off by default and adds nothing', () {
      const h = PromptHelpers();
      expect(h.emojis, isFalse);
      expect(h.buildText(), isNull);
      expect(h.anyActive, isFalse);
    });

    test('advises occasional emojis only when switched on', () {
      const h = PromptHelpers(emojis: true);
      expect(h.anyActive, isTrue);
      final text = h.buildText()!;
      expect(text, contains('EMOJIS'));
      expect(text, contains('here and there'));
      expect(text, contains('at most one or two'));
    });

    test('survives a JSON round trip and old saved values stay off', () {
      final restored = PromptHelpers.fromJson(
        const PromptHelpers(emojis: true).toJson(),
      );
      expect(restored.emojis, isTrue);
      expect(PromptHelpers.fromJson({'formatting': true}).emojis, isFalse);
    });

    test('copyWith toggles it without touching other helpers', () {
      final h = const PromptHelpers(formatting: true).copyWith(emojis: true);
      expect(h.emojis, isTrue);
      expect(h.formatting, isTrue);
    });
  });

  group('PromptHelpers Think First vs native reasoning', () {
    test('is sent when native reasoning is off', () {
      const h = PromptHelpers(thinkFirst: true);
      expect(h.buildText(), contains('THINK FIRST'));
      expect(h.thinkFirstActive(nativeReasoning: false), isTrue);
    });

    test('is not sent while native reasoning is on', () {
      const h = PromptHelpers(thinkFirst: true);
      expect(h.buildText(nativeReasoning: true), isNull);
      expect(h.toRuntimeBlocks(nativeReasoning: true), isEmpty);
      expect(h.thinkFirstActive(nativeReasoning: true), isFalse);
    });

    test('other helpers still go out when native reasoning is on', () {
      const h = PromptHelpers(thinkFirst: true, emojis: true);
      final text = h.buildText(nativeReasoning: true)!;
      expect(text, contains('EMOJIS'));
      expect(text, isNot(contains('THINK FIRST')));
    });
  });

  group('PromptHelpers impersonation', () {
    test('lifts the rules that forbid writing the user', () {
      const h = PromptHelpers(
        userAgency: true,
        userNameAccuracy: true,
        formatting: true,
        emojis: true,
      );
      final text = h.forImpersonation().buildText()!;
      expect(text, isNot(contains('USER AGENCY')));
      expect(text, isNot(contains('active persona name')));
      expect(text, contains('*asterisks*'));
      expect(text, contains('EMOJIS'));
    });

    test('is empty when only user-protecting helpers were on', () {
      const h = PromptHelpers(userAgency: true);
      expect(h.forImpersonation().buildText(), isNull);
    });
  });
}
