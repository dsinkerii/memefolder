import 'package:flutter_test/flutter_test.dart';
import 'package:memefolder/backend/tokenizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HuggingFaceTokenizer clipTok;

  setUp(() {
    clipTok = HuggingFaceTokenizer.fromFile(
      '/tmp/onnx_models/clip/tokenizer.json',
    );
  });

  group('CLIP tokenizer', () {
    test('hello world', () {
      final expected = [
        49406,
        3306,
        1002,
        49407,
      ];
      final actual = clipTok.encode('hello world', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('HELLO WORLD (lowercase)', () {
      final expected = [
        49406,
        3306,
        1002,
        49407,
      ];
      final actual = clipTok.encode('HELLO WORLD', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('Hello World (mixed case)', () {
      final expected = [
        49406,
        3306,
        1002,
        49407,
      ];
      final actual = clipTok.encode('Hello World', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('hello', () {
      final expected = [
        49406,
        3306,
        49407,
      ];
      final actual = clipTok.encode('hello', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('a cute cat', () {
      final expected = [
        49406,
        320,
        2242,
        2368,
        49407,
      ];
      final actual = clipTok.encode('a cute cat', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('funny meme', () {
      final expected = [
        49406,
        3789,
        9169,
        49407,
      ];
      final actual = clipTok.encode('funny meme', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('dancing baby', () {
      final expected = [
        49406,
        6226,
        1794,
        49407,
      ];
      final actual = clipTok.encode('dancing baby', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('123 digits', () {
      final expected = [
        49406,
        272,
        273,
        274,
        49407,
      ];
      final actual = clipTok.encode('123', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('A photo of a cat', () {
      final expected = [
        49406,
        320,
        1125,
        539,
        320,
        2368,
        49407,
      ];
      final actual = clipTok.encode('A photo of a cat', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('the quick brown fox jumps over the lazy dog', () {
      final expected = [
        49406,
        518,
        3712,
        2866,
        3240,
        18911,
        962,
        518,
        10753,
        1929,
        49407,
      ];
      final actual = clipTok.encode(
        'the quick brown fox jumps over the lazy dog',
        addSpecialTokens: true,
      );
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('empty string', () {
      final expected = [
        49406,
        49407,
      ];
      final actual = clipTok.encode('', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('encodeClip pads to 77', () {
      final padded = clipTok.encodeClip('hello world');
      expect(padded.length, equals(77));
      expect(padded[0], equals(49406));
      expect(padded[1], equals(3306));
      expect(padded[2], equals(1002));
      expect(padded[3], equals(49407));
      // Rest should be padded with 49407
      for (int i = 4; i < 77; i++) {
        expect(padded[i], equals(49407),
            reason: 'Index $i should be padding token');
      }
    });
  });
}
