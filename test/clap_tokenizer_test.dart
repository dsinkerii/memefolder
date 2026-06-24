import 'package:flutter_test/flutter_test.dart';
import 'package:memefolder/backend/tokenizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HuggingFaceTokenizer clapTok;

  setUp(() {
    clapTok = HuggingFaceTokenizer.fromFile(
      '/tmp/onnx_models/clap/tokenizer.json',
    );
  });

  group('CLAP tokenizer', () {
    test('hello world', () {
      final expected = [
        0,  // <s>
        42891,  // hello
        232,   // world
        2,  // </s>
      ];
      final actual = clapTok.encode('hello world', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('a cute cat', () {
      final expected = [
        0,
        102,
        11962,
        4758,
        2,
      ];
      final actual = clapTok.encode('a cute cat', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('dancing baby', () {
      final expected = [
        0,
        417,
        7710,
        1928,
        2,
      ];
      final actual = clapTok.encode('dancing baby', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('funny meme', () {
      final expected = [
        0,
        18317,
        2855,
        25426,
        2,
      ];
      final actual = clapTok.encode('funny meme', addSpecialTokens: true);
      expect(actual.take(expected.length).toList(), equals(expected));
    });

    test('encodeClap pads to 77', () {
      final padded = clapTok.encodeClap('hello world');
      expect(padded.length, equals(77));
      expect(padded[0], equals(0));  // <s>
      expect(padded[1], equals(42891));
      expect(padded[2], equals(232));
      expect(padded[3], equals(2));  // </s>
      for (int i = 4; i < 77; i++) {
        expect(padded[i], equals(1), reason: 'Index $i should be pad token');
      }
    });
  });
}
