import 'package:flutter/material.dart';
import 'package:flutter_vector_icons/flutter_vector_icons.dart';
import 'package:memefolder/backend/system_specs.dart';
import 'package:memefolder/helpers/new_dialog.dart';

void showRuntimeManagerDialog(BuildContext context) {
  showScaleDialog(
    context: context,
    width: 640,
    builder: (dialogCtx) => const _RuntimeManagerDialog(),
  );
}

class _RuntimeManagerDialog extends StatefulWidget {
  const _RuntimeManagerDialog();

  @override
  State<_RuntimeManagerDialog> createState() => _RuntimeManagerDialogState();
}

class _RuntimeManagerDialogState extends State<_RuntimeManagerDialog> {
  SystemSpecs? _specs;
  bool _loadingSpecs = true;
  String _tier = 'low';

  @override
  void initState() {
    super.initState();
    _loadSpecs();
  }

  Future<void> _loadSpecs() async {
    final specs = await SystemSpecs.detect();
    if (!mounted) return;
    setState(() {
      _specs = specs;
      _loadingSpecs = false;
      _tier = specs.tierRecommendation;
    });
    debugPrint('[runtime] system specs: ${specs.cpuModel}, ${specs.ramGb}GB RAM, ${specs.vramGb}GB VRAM, tier=${specs.tierRecommendation}');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 6),
          Icon(Ionicons.hardware_chip_sharp, size: 48, color: cs.primary),
          const SizedBox(height: 10),
          Text(
            "Runtime Manager",
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 24,
              fontFamily: "Syne",
              color: cs.onSurface,
              fontVariations: const [
                FontVariation('wdth', 2800),
                FontVariation('wght', 700),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            "system information",
            style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          _buildSpecsCard(cs),
          const SizedBox(height: 14),
          _buildTierSelector(cs),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text("Done", style: TextStyle(color: cs.primary)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSpecsCard(ColorScheme cs) {
    if (_loadingSpecs) {
      return _card(cs, [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: cs.primary,
              ),
            ),
            const SizedBox(width: 12),
            Text('Detecting system specs...',
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      ]);
    }

    final s = _specs!;
    return _card(cs, [
      Text('System Specs', style: _sectionTitle(cs)),
      const SizedBox(height: 10),
      _specRow(cs, Icons.memory, 'CPU', s.cpuModel),
      _specRow(cs, Icons.scatter_plot, 'Cores', '${s.cpuCores}'),
      _specRow(cs, Icons.storage, 'RAM', '${s.ramGb.toStringAsFixed(1)} GB'),
      Divider(height: 12, color: cs.onSurface.withAlpha(80)),
      _specRow(cs, Icons.videocam, 'GPU', s.gpuName),
      _specRow(cs, Icons.memory,
          s.isIntegratedGpu ? 'Shared Mem' : 'VRAM',
          s.isIntegratedGpu
              ? '~${s.vramGb.toStringAsFixed(1)} GB (from RAM)'
              : '${s.vramGb.toStringAsFixed(1)} GB'),
    ]);
  }

  Widget _buildTierSelector(ColorScheme cs) {
    return _card(cs, [
      Row(
        children: [
          Text('Resource Tier', style: _sectionTitle(cs)),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cs.primary.withAlpha(30),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'recommended: ${_specs?.tierRecommendation ?? "low"}',
              style: TextStyle(fontSize: 11, color: cs.primary),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          _tierChip(cs, 'low', 'Low'),
          const SizedBox(width: 8),
          _tierChip(cs, 'high', 'High'),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        _tier == 'high'
            ? 'High resource profile'
            : 'Low resource profile',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
    ]);
  }

  Widget _tierChip(ColorScheme cs, String tier, String label) {
    final selected = _tier == tier;
    return GestureDetector(
      onTap: () => setState(() => _tier = tier),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? cs.primary.withAlpha(40) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? cs.primary : cs.onSurface.withAlpha(60),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? cs.primary : cs.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _specRow(
      ColorScheme cs, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: cs.primary),
          const SizedBox(width: 8),
          SizedBox(
            width: 65,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                    fontFamily: "Syne")),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface,
                    fontFamily: "Hack"),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Widget _card(ColorScheme cs, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  TextStyle _sectionTitle(ColorScheme cs) => TextStyle(
        fontFamily: "Syne",
        fontVariations: const [FontVariation('wght', 600)],
        fontSize: 14,
        color: cs.onSurface,
      );
}
