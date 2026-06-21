import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:memefolder/prefs.dart';

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService instance = AudioPlayerService._();
  AudioPlayerService._();

  AudioPlayer? _player;
  String? _currentPath;
  String? _currentTitle;
  List<double>? _currentWaveform;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _loading = false;
  bool _playerFailed = false;
  double _volume = 1.0;
  bool _looping = false;

  String? get currentPath => _currentPath;
  String? get currentTitle => _currentTitle;
  List<double>? get currentWaveform => _currentWaveform;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get playing => _playing;
  bool get loading => _loading;
  bool get playerFailed => _playerFailed;
  bool get hasActiveTrack => _currentPath != null;
  double get volume => _volume;
  bool get looping => _looping;

  Future<void> _ensurePlayer() async {
    if (_player != null) return;
    if (_playerFailed) return;
    try {
      _volume = PlayerPrefs.getFloat('audio_volume', 1.0).clamp(0.0, 1.0);
      _player = AudioPlayer();
      _player!.positionStream.listen((pos) {
        _position = pos;
        notifyListeners();
      });
      _player!.durationStream.listen((dur) {
        if (dur != null) _duration = dur;
        notifyListeners();
      });
      _player!.playerStateStream.listen((state) {
        _playing = state.playing;
        if (state.processingState == ProcessingState.completed) {
          _playing = false;
        }
        notifyListeners();
      });
    } catch (e) {
      debugPrint('AudioPlayerService: init failed: $e');
      _playerFailed = true;
      _player = null;
      notifyListeners();
    }
  }

  Future<void> play(String path,
      {String? title, List<double>? waveform}) async {
    if (_currentPath == path && _player != null) {
      if (_playing) {
        await _player!.pause();
      } else {
        await _player!.play();
      }
      _playing = _player?.playing ?? false;
      notifyListeners();
      return;
    }

    await stop();
    await _ensurePlayer();
    if (_player == null) return;

    _loading = true;
    notifyListeners();

    try {
      _currentPath = path;
      _currentTitle = title;
      _currentWaveform = waveform;
      _position = Duration.zero;
      _duration = Duration.zero;
      notifyListeners();

      await _player!.setVolume(_volume);
      await _player!.setLoopMode(_looping ? LoopMode.one : LoopMode.off);
      await _player!.setFilePath(path);
      await _player!.play();
      _playing = true;
    } catch (e) {
      debugPrint('AudioPlayerService: play error: $e');
      _playing = false;
    }

    _loading = false;
    notifyListeners();
  }

  Future<void> pause() async {
    if (_player == null) return;
    await _player!.pause();
    _playing = false;
    notifyListeners();
  }

  Future<void> resume() async {
    if (_player == null) return;
    if (_position >= _duration && _duration > Duration.zero) {
      await _player!.seek(Duration.zero);
      _position = Duration.zero;
    }
    await _player!.play();
    _playing = true;
    notifyListeners();
  }

  Future<void> seek(Duration position) async {
    if (_player == null) return;
    await _player!.seek(position);
    _position = position;
    notifyListeners();
  }

  Future<void> seekFraction(double fraction) async {
    if (_player == null || _duration.inMilliseconds <= 0) return;
    final pos = Duration(
      milliseconds: (fraction * _duration.inMilliseconds).round(),
    );
    await _player!.seek(pos);
    _position = pos;
    notifyListeners();
  }

  Future<void> stop() async {
    if (_player == null) return;
    await _player!.stop();
    _currentPath = null;
    _currentTitle = null;
    _currentWaveform = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _playing = false;
    notifyListeners();
  }

  Future<void> setVolume(double vol) async {
    _volume = vol.clamp(0.0, 1.0);
    notifyListeners();
    if (_player != null) {
      await _player!.setVolume(_volume);
    }
    PlayerPrefs.setFloat('audio_volume', _volume);
  }

  Future<void> toggleLoop() async {
    _looping = !_looping;
    if (_player != null) {
      await _player!.setLoopMode(_looping ? LoopMode.one : LoopMode.off);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }
}
