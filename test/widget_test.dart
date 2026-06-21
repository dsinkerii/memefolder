import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:memefolder/widgets/file_preview.dart';

void main() {
  testWidgets('file preview shows empty placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FilePreviewPane(file: null))),
    );

    expect(find.byIcon(Icons.insert_drive_file), findsOneWidget);
  });
}
