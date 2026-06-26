import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PlayerPrefs {
  static late SharedPreferences _prefs;
  static final storage = FlutterSecureStorage();

  static final Map<String, dynamic> _cache = {};

  static Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  static Future<void> deleteAll() async {
    try {
      await storage.deleteAll();
    } catch (e) {
      debugPrint('[prefs] secure storage deleteAll failed: $e');
    }
    await _prefs.clear();
    _cache.clear();
  }

  static Future<void> reload() async {
    await _prefs.reload();
  }

  static Future<String> getSecureString(
    String key, [
    String defValue = "",
  ]) async {
    final prefixedKey = 'SECURE_$key';

    if (_cache.containsKey(prefixedKey)) {
      return _cache[prefixedKey] as String;
    }

    try {
      final secureVal = await storage.read(key: key);
      if (secureVal != null) {
        _cache[prefixedKey] = secureVal;
        return secureVal;
      }
    } catch (e) {
      /* swallow */
    }

    return defValue;
  }

  static Future setSecureString(String key, String value) async {
    try {
      await storage.write(key: key, value: value);
      _cache.remove('SECURE_$key');
      _cache.remove(key);
    } catch (e) {
      debugPrint("Secure storage write failed: $e");
      rethrow;
    }
  }

  static Future<void> deleteSecureString(String key) async {
    try {
      await storage.delete(key: key);
      _cache.remove('SECURE_$key');
      _cache.remove(key);
    } catch (e) {
      debugPrint("Secure storage delete failed: $e");
      rethrow;
    }
  }

  static String getString(String key, [String defValue = ""]) {
    if (_cache.containsKey(key)) {
      return _cache[key] as String;
    }

    final val = _prefs.getString(key);
    if (val != null) {
      _cache[key] = val;
    }

    return val ?? defValue;
  }

  static Future<bool> setString(String key, String value) async {
    await _prefs.setString(key, value);
    _cache.remove('SECURE_$key');
    _cache.remove(key);
    return true;
  }

  static List<String> getStringList(
    String key, [
    List<String> defValue = const [],
  ]) {
    if (_cache.containsKey(key)) {
      return List<String>.from(_cache[key] as List);
    }

    List<String>? val;
    try {
      val = _prefs.getStringList(key);
    } catch (_) {
      _prefs.remove(key);
    }

    if (val != null) {
      _cache[key] = val;
    }

    return val ?? defValue;
  }

  static Future<bool> setStringList(String key, List<String> value) async {
    await _prefs.setStringList(key, value);
    _cache.remove('SECURE_$key');
    _cache.remove(key);
    return true;
  }

  static int getInt(String key, [int defValue = 0]) {
    if (_cache.containsKey(key)) {
      return _cache[key] as int;
    }

    final val = _prefs.getInt(key);
    if (val != null) {
      _cache[key] = val;
    }

    return val ?? defValue;
  }

  static Future<bool> setInt(String key, int value) async {
    await _prefs.setInt(key, value);
    _cache.remove('SECURE_$key');
    _cache.remove(key);
    return true;
  }

  static Future<bool> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
    _cache.remove('SECURE_$key');
    _cache.remove(key);
    return true;
  }

  static double getFloat(String key, [double defValue = 0.0]) {
    if (_cache.containsKey(key)) {
      return _cache[key] as double;
    }

    final val = _prefs.getDouble(key);
    if (val != null) {
      _cache[key] = val;
    }

    return val ?? defValue;
  }

  static bool getBool(String key, bool defValue) {
    if (_cache.containsKey(key)) {
      return _cache[key] as bool;
    }

    final val = _prefs.getBool(key);
    if (val != null) {
      _cache[key] = val;
    }

    return val ?? defValue;
  }

  static Future<bool> setFloat(String key, double value) async {
    await _prefs.setDouble(key, value);
    _cache.remove('SECURE_$key');
    _cache.remove(key);
    return true;
  }
}
