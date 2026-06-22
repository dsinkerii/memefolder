import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memefolder/prefs.dart';

class CustomTagsStore extends ChangeNotifier {
  static final instance = CustomTagsStore._();
  CustomTagsStore._();

  Set<String> _tags = {};

  Set<String> get tags => _tags;

  void load() {
    final raw = PlayerPrefs.getString("custom_tags", '{}');
    if (raw.isNotEmpty) {
      try {
        _tags = Map<String, String>.from(jsonDecode(raw)).keys.toSet();
      } catch (_) {
        _tags = {'dsinkerii'};
      }
    } else {
      _tags = {'dsinkerii'};
    }
    notifyListeners();
  }

  /// Call after saving tags in the dialog to refresh everywhere.
  void refresh() {
    load();
  }
}
