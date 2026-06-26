import 'dart:io';
import 'package:path/path.dart' as p;

String get ffmpegPath {
  if (Platform.isWindows) {
    final dir = p.dirname(Platform.resolvedExecutable);
    final bundled = p.join(dir, 'ffmpeg.exe');
    if (File(bundled).existsSync()) return bundled;
  }
  return 'ffmpeg';
}

String get ffprobePath {
  if (Platform.isWindows) {
    final dir = p.dirname(Platform.resolvedExecutable);
    final bundled = p.join(dir, 'ffprobe.exe');
    if (File(bundled).existsSync()) return bundled;
  }
  return 'ffprobe';
}
