import 'dart:io';

class SystemSpecs {
  final String cpuModel;
  final int cpuCores;
  final int cpuClockKhz;
  final double ramGb;
  final String gpuName;
  final double vramGb;
  final bool isIntegratedGpu;

  const SystemSpecs({
    required this.cpuModel,
    required this.cpuCores,
    required this.cpuClockKhz,
    required this.ramGb,
    required this.gpuName,
    required this.vramGb,
    required this.isIntegratedGpu,
  });

  bool get isHighEnd =>
      vramGb >= 2.0 && ramGb >= 8.0 && cpuClockKhz >= 8000 || cpuCores >= 2;

  bool get supportsGpuAcceleration => !isIntegratedGpu && vramGb >= 2.0;

  String get recommendedGpuProvider {
    if (!supportsGpuAcceleration) return 'CPU';
    if (Platform.isLinux && gpuName.toLowerCase().contains('nvidia')) {
      return 'CUDA';
    }
    if (Platform.isLinux && (gpuName.toLowerCase().contains('amd') || gpuName.toLowerCase().contains('radeon'))) {
      return 'ROCm';
    }
    if (Platform.isWindows) return 'DirectML';
    if (Platform.isMacOS) return 'CoreML';
    return 'CPU';
  }

  String get tierRecommendation => isHighEnd ? 'high' : 'low';

  static Future<SystemSpecs> detect() async {
    if (Platform.isLinux) return _detectLinux();
    if (Platform.isWindows) return _detectWindows();
    if (Platform.isMacOS) return _detectMacos();
    return _fallback();
  }

  static Future<SystemSpecs> _detectLinux() async {
    String cpuModel = 'Unknown CPU';
    int cpuCores = 1;
    int cpuClockKhz = 0;
    double ramGb = 0;
    String gpuName = 'Unknown GPU';
    double vramGb = 0;
    bool isIntegrated = true;

    try {
      final lscpu = await Process.run('lscpu', []);
      final output = lscpu.stdout.toString();
      for (final line in output.split('\n')) {
        if (line.startsWith('Model name:')) {
          cpuModel = line.split(':').last.trim();
        } else if (line.startsWith('CPU(s):') && !line.contains('NUMA')) {
          cpuCores = int.tryParse(line.split(':').last.trim()) ?? 1;
        } else if (line.startsWith('CPU max MHz:')) {
          final mhz = double.tryParse(line.split(':').last.trim()) ?? 0;
          cpuClockKhz = (mhz * 1000).toInt();
        }
      }
    } catch (_) {}

    try {
      final free = await Process.run('free', ['-b']);
      final lines = free.stdout.toString().split('\n');
      for (final line in lines) {
        if (line.startsWith('Mem:')) {
          final parts = line.split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final bytes = int.tryParse(parts[1]) ?? 0;
            ramGb = bytes / (1024 * 1024 * 1024);
          }
          break;
        }
      }
    } catch (_) {}

    try {
      final nvidia = await Process.run('nvidia-smi', [
        '--query-gpu=name,memory.total',
        '--format=csv,noheader,nounits',
      ]);
      if (nvidia.exitCode == 0) {
        final line = nvidia.stdout.toString().trim();
        final parts = line.split(', ');
        if (parts.length >= 2) {
          gpuName = parts[0].trim();
          final vramMb = double.tryParse(parts[1].trim()) ?? 0;
          vramGb = vramMb / 1024;
          isIntegrated = false;
        }
      }
    } catch (_) {}

    if (vramGb == 0) {
      try {
        final rocm = await Process.run('rocm-smi', [
          '--showmeminfo',
          'vram',
          '--csv',
        ]);
        if (rocm.exitCode == 0) {
          final lines = rocm.stdout.toString().split('\n');
          for (final line in lines) {
            if (line.contains('VRAM Total Memory')) continue;
            final parts = line.split(',');
            if (parts.length >= 2) {
              final bytes = int.tryParse(parts[1].trim()) ?? 0;
              if (bytes > 0) {
                vramGb = bytes / (1024 * 1024 * 1024);
                gpuName = 'AMD GPU';
                isIntegrated = false;
              }
            }
          }
        }
      } catch (_) {}
    }

    if (vramGb == 0) {
      vramGb = ramGb;
      gpuName = 'Integrated GPU (estimated from RAM)';
      isIntegrated = true;
    }

    return SystemSpecs(
      cpuModel: cpuModel,
      cpuCores: cpuCores,
      cpuClockKhz: cpuClockKhz,
      ramGb: ramGb,
      gpuName: gpuName,
      vramGb: vramGb,
      isIntegratedGpu: isIntegrated,
    );
  }

  static Future<SystemSpecs> _detectWindows() async {
    String cpuModel = 'Unknown CPU';
    int cpuCores = 1;
    int cpuClockKhz = 0;
    double ramGb = 0;
    String gpuName = 'Unknown GPU';
    double vramGb = 0;
    bool isIntegrated = true;

    try {
      final result = await Process.run('wmic', [
        'cpu',
        'get',
        'Name,NumberOfCores,MaxClockSpeed',
        '/format:list',
      ]);
      final output = result.stdout.toString();
      for (final line in output.split('\n')) {
        if (line.startsWith('MaxClockSpeed=')) {
          cpuClockKhz = int.tryParse(line.split('=').last.trim()) ?? 0;
        } else if (line.startsWith('Name=')) {
          cpuModel = line.split('=').last.trim();
        } else if (line.startsWith('NumberOfCores=')) {
          cpuCores = int.tryParse(line.split('=').last.trim()) ?? 1;
        }
      }
    } catch (_) {}

    try {
      final result = await Process.run('wmic', [
        'memorychip',
        'get',
        'Capacity',
        '/format:list',
      ]);
      final output = result.stdout.toString();
      int totalBytes = 0;
      for (final line in output.split('\n')) {
        if (line.startsWith('Capacity=')) {
          final bytes = int.tryParse(line.split('=').last.trim()) ?? 0;
          totalBytes += bytes;
        }
      }
      ramGb = totalBytes / (1024 * 1024 * 1024);
    } catch (_) {}

    try {
      final result = await Process.run('wmic', [
        'path',
        'win32_videocontroller',
        'get',
        'Name,AdapterRAM',
        '/format:list',
      ]);
      final output = result.stdout.toString();
      String? name;
      int adapterRam = 0;
      for (final line in output.split('\n')) {
        if (line.startsWith('Name=')) {
          name = line.split('=').last.trim();
        } else if (line.startsWith('AdapterRAM=')) {
          adapterRam = int.tryParse(line.split('=').last.trim()) ?? 0;
        }
      }
      if (name != null && name.isNotEmpty) {
        gpuName = name;
        if (adapterRam > 0) {
          vramGb = adapterRam / (1024 * 1024 * 1024);
          isIntegrated = false;
        }
      }
    } catch (_) {}

    if (vramGb == 0) {
      vramGb = ramGb;
      gpuName = 'Integrated GPU (estimated from RAM)';
      isIntegrated = true;
    }

    return SystemSpecs(
      cpuModel: cpuModel,
      cpuCores: cpuCores,
      cpuClockKhz: cpuClockKhz,
      ramGb: ramGb,
      gpuName: gpuName,
      vramGb: vramGb,
      isIntegratedGpu: isIntegrated,
    );
  }

  static Future<SystemSpecs> _detectMacos() async {
    String cpuModel = 'Unknown CPU';
    int cpuCores = 1;
    int cpuClockKhz = 0;
    double ramGb = 0;
    String gpuName = 'Unknown GPU';
    double vramGb = 0;
    bool isIntegrated = true;

    try {
      final result = await Process.run('sysctl', [
        '-n',
        'machdep.cpu.brand_string',
      ]);
      cpuModel = result.stdout.toString().trim();
    } catch (_) {}

    try {
      final result = await Process.run('sysctl', ['-n', 'hw.ncpu']);
      cpuCores = int.tryParse(result.stdout.toString().trim()) ?? 1;
    } catch (_) {}

    try {
      final result = await Process.run('sysctl', ['-n', 'hw.cpufrequency']);
      cpuClockKhz =
          (int.tryParse(result.stdout.toString().trim()) ?? 0) ~/ 1000;
    } catch (_) {}

    try {
      final result = await Process.run('sysctl', ['-n', 'hw.memsize']);
      final bytes = int.tryParse(result.stdout.toString().trim()) ?? 0;
      ramGb = bytes / (1024 * 1024 * 1024);
    } catch (_) {}

    try {
      final result = await Process.run('system_profiler', [
        'SPDisplaysDataType',
      ]);
      final output = result.stdout.toString();
      for (final line in output.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.startsWith('Chipset Model:')) {
          gpuName = trimmed.split(':').last.trim();
        } else if (trimmed.startsWith('VRAM (Total):')) {
          final match = RegExp(r'(\d+)\s*MB').firstMatch(trimmed);
          if (match != null) {
            vramGb = int.parse(match.group(1)!) / 1024;
            isIntegrated = false;
          }
        }
      }
    } catch (_) {}

    if (vramGb == 0) {
      vramGb = ramGb;
      gpuName = 'Integrated GPU (estimated from RAM)';
      isIntegrated = true;
    }

    return SystemSpecs(
      cpuModel: cpuModel,
      cpuCores: cpuCores,
      cpuClockKhz: cpuClockKhz,
      ramGb: ramGb,
      gpuName: gpuName,
      vramGb: vramGb,
      isIntegratedGpu: isIntegrated,
    );
  }

  static SystemSpecs _fallback() {
    return const SystemSpecs(
      cpuModel: 'Unknown CPU',
      cpuCores: 1,
      cpuClockKhz: 0,
      ramGb: 0,
      gpuName: 'Unknown GPU',
      vramGb: 0,
      isIntegratedGpu: true,
    );
  }
}
