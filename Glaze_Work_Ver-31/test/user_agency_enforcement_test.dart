import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_helpers.dart';
import 'package:glaze_flutter/core/llm/reply_trimmer.dart';

void main() {
  group('enforceUserAgency', () {
    test('cuts a sentence that opens with the user name and an action', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          'Maya waits. Sam takes her hand.',
          'Sam',
        ),
        'Maya waits.',
      );
    });

    test('cuts second-person actions in plain prose', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          'Maya smiles at the door. You nod and step inside. She waits.',
          'Sam',
        ),
        'Maya smiles at the door.',
      );
    });

    test('cuts second-person actions in *asterisk* narration', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          '*Maya reaches out.* "Come in," she says. '
          '*You smile and take her hand.*',
          'Sam',
        ),
        '*Maya reaches out.* "Come in," she says.',
      );
    });

    test('cuts a body reaction written for the user', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          '"Come in," Maya says. Your heart races as you step inside.',
          'Sam',
        ),
        '"Come in," Maya says.',
      );
    });

    test('cuts the user\'s quoted words tagged with their name', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          'Maya waits by the door. "I missed you," Sam says.',
          'Sam',
        ),
        'Maya waits by the door.',
      );
    });

    test('catches a possessive body part and a first name', () {
      expect(
        ReplyTrimmer.enforceUserAgency(
          'Maya frowns. Sam\'s eyes widen in shock.',
          'Sam',
        ),
        'Maya frowns.',
      );
      expect(
        ReplyTrimmer.enforceUserAgency(
          'Maya waits. Noah steps closer.',
          'Noah Smith',
        ),
        'Maya waits.',
      );
    });

    test('drops a violating opening instead of keeping the whole reply', () {
      expect(
        ReplyTrimmer.enforceUserAgency('You nod. Maya smiles back.', 'Sam'),
        'Maya smiles back.',
      );
      expect(
        ReplyTrimmer.enforceUserAgency('Sam: hi\nMaya smiles.', 'Sam'),
        'Maya smiles.',
      );
    });

    test('leaves replies that only speak for others untouched', () {
      const ok = 'Maya says "You are late." She crosses her arms.';
      expect(ReplyTrimmer.enforceUserAgency(ok, 'Sam'), ok);
      const unquoted = '*Maya looks up.* You came back.';
      expect(ReplyTrimmer.enforceUserAgency(unquoted, 'Sam'), unquoted);
    });
  });

  group('User Agency helper', () {
    test('the rule covers second person and names the user macro', () {
      const text = PromptHelpers.userAgencyText;
      expect(text, contains('{{user}}'));
      expect(text, contains('second person'));
      expect(text, contains('absolute rule'));
    });

    test('stop sequences cover labels and action lines', () {
      const h = PromptHelpers(userAgency: true);
      expect(h.stopSequencesFor('Sam'), [
        '\nSam:',
        '\n*Sam ',
        '\nSam ',
        '\nUser:',
      ]);
    });
  });
}
