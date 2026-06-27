import 'dart:io';

/// writes checkpoint logs directly to stderr for live console output.
/// no file I/O - no permission issues, no missing directories.
class CrashLogger {
  static final CrashLogger instance = CrashLogger._();
  CrashLogger._();

  void mark(String stage, Map<String, Object?> details) {
    final parts = <String>['stage=$stage'];
    for (final e in details.entries) {
      parts.add('${e.key}=${e.value}');
    }
    stderr.writeln('[memefolder] ${parts.join(' ')}');
  }

  void clear() {}
}
