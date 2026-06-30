import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class MelFFI {
  late final DynamicLibrary _lib;
  late final void Function(Pointer<Float>, int, Pointer<Float>) _computeClapMel;
  late final void Function(Pointer<Float>, int, Pointer<Float>) _computeWhisperMel;

  MelFFI() {
    _lib = _loadLibrary();
    final melInit = _lib.lookupFunction<Void Function(), void Function()>(
      'mel_init',
    );
    melInit();
    _computeClapMel = _lib.lookupFunction<
        Void Function(Pointer<Float>, Int32, Pointer<Float>),
        void Function(Pointer<Float>, int, Pointer<Float>)>('compute_clap_mel');
    _computeWhisperMel = _lib.lookupFunction<
        Void Function(Pointer<Float>, Int32, Pointer<Float>),
        void Function(Pointer<Float>, int, Pointer<Float>)>('compute_whisper_mel');
  }

  static DynamicLibrary _loadLibrary() {
    if (Platform.isLinux) {
      try {
        return DynamicLibrary.open('libmel_ffi.so');
      } catch (_) {}
      // dev: look relative to project root
      final devPath = '${Directory.current.path}/c_ffi/build/libmel_ffi.so';
      if (File(devPath).existsSync()) {
        return DynamicLibrary.open(devPath);
      }
      throw UnsupportedError(
        'libmel_ffi.so not found. Build it: cd c_ffi && cmake -B build && cmake --build build',
      );
    } else if (Platform.isMacOS) {
      try {
        return DynamicLibrary.open('libmel_ffi.dylib');
      } catch (_) {}
      final devPath = '${Directory.current.path}/c_ffi/build/libmel_ffi.dylib';
      if (File(devPath).existsSync()) {
        return DynamicLibrary.open(devPath);
      }
      throw UnsupportedError(
        'libmel_ffi.dylib not found. Build it: cd c_ffi && cmake -B build && cmake --build build',
      );
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('mel_ffi.dll');
    }
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  static const int clapSampleRate = 48000;
  static const int clapMaxSamples = 480000;
  static const int clapNFrames = 1001;
  static const int clapNMels = 64;
  static const int clapOutputSize = clapNFrames * clapNMels;

  static const int whisperSampleRate = 16000;
  static const int whisperMaxSamples = 480000;
  static const int whisperNFrames = 3000;
  static const int whisperNMels = 80;
  static const int whisperOutputSize = whisperNFrames * whisperNMels;

  Float32List computeClapMel(Float32List pcm) {
    final output = calloc<Float>(clapOutputSize);
    final input = calloc<Float>(pcm.length);
    try {
      input.asTypedList(pcm.length).setAll(0, pcm);
      _computeClapMel(input, pcm.length, output);
      return Float32List.fromList(output.asTypedList(clapOutputSize));
    } finally {
      calloc.free(output);
      calloc.free(input);
    }
  }

  Float32List computeWhisperMel(Float32List pcm) {
    final output = calloc<Float>(whisperOutputSize);
    final input = calloc<Float>(pcm.length);
    try {
      input.asTypedList(pcm.length).setAll(0, pcm);
      _computeWhisperMel(input, pcm.length, output);
      return Float32List.fromList(output.asTypedList(whisperOutputSize));
    } finally {
      calloc.free(output);
      calloc.free(input);
    }
  }

  void dispose() {
    _lib = DynamicLibrary.process();
  }
}
