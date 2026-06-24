import 'lib/backend/tokenizer.dart';

void main() {
  // Test CLIP tokenizer
  final clipTok = HuggingFaceTokenizer.fromFile('/tmp/onnx_models/clip/tokenizer.json');
  final tests = ['hello world', 'a cat playing piano', 'funny meme template'];
  for (final t in tests) {
    final ids = clipTok.encodeClip(t);
    print('CLIP "$t": ${ids.take(10).toList()}...');
  }

  // Test CLAP tokenizer
  final clapTok = HuggingFaceTokenizer.fromFile('/tmp/onnx_models/clap/tokenizer.json');
  for (final t in tests) {
    final ids = clapTok.encodeClap(t);
    print('CLAP "$t": ${ids.take(10).toList()}...');
  }
}
