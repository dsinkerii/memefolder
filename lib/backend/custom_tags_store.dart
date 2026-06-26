import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:memefolder/prefs.dart';

class CustomTagsStore extends ChangeNotifier {
  static final instance = CustomTagsStore._();
  CustomTagsStore._();

  Map<String, String> _tags = {};

  Set<String> get tagNames => _tags.keys.toSet();
  Map<String, String> get tags => _tags;

  void load() {
    final raw = PlayerPrefs.getString("custom_tags", '{}');
    if (raw.isNotEmpty) {
      try {
        _tags = Map<String, String>.from(jsonDecode(raw));
      } catch (_) {
        _tags = {'dsinkerii': 'awesome developer'};
      }
    } else {
      _tags = {'dsinkerii': 'awesome developer'};
    }
    notifyListeners();
  }

  /// Call after saving tags in the dialog to refresh everywhere.
  void refresh() {
    load();
  }
}
