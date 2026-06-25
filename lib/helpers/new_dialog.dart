import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:memefolder/config/theme.dart';

Future<T?> showScaleDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double? width,
  EdgeInsetsGeometry contentPadding = const EdgeInsets.fromLTRB(16, 16, 16, 8),
  EdgeInsets insetPadding = const EdgeInsets.symmetric(
    horizontal: 40,
    vertical: 24,
  ),
  BoxConstraints constraints = const BoxConstraints(minWidth: 280),
  bool barrierDismissible = true,
  double? maxHeight,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'ok',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (dialogCtx, animation, secondaryAnimation) {
      return const SizedBox.shrink();
    },
    transitionBuilder: (dialogCtx, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeInOutCubicEmphasized,
      );
      final media = MediaQuery.of(dialogCtx);
      final effectiveInset = EdgeInsets.only(
        top: media.padding.top + insetPadding.top,
        bottom: media.padding.bottom + insetPadding.bottom,
        left: insetPadding.left,
        right: insetPadding.right,
      );
      final availableWidth = media.size.width - effectiveInset.horizontal;
      final availableHeight = media.size.height - effectiveInset.vertical;
      final cappedHeight = maxHeight?.clamp(0.0, availableHeight) ?? availableHeight;
      final dialogConstraints = constraints.enforce(
        BoxConstraints(
          maxWidth: width == null
              ? availableWidth
              : width.clamp(0, availableWidth),
          maxHeight: cappedHeight,
        ),
      );

      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: barrierDismissible
                    ? () => Navigator.of(dialogCtx).pop()
                    : null,
                child: Container(color: Colors.black38),
              ),
            ),
            Center(
              child: Padding(
                padding: effectiveInset,
                child: ScaleTransition(
                  scale: curved,
                  child: ConstrainedBox(
                    constraints: dialogConstraints,
                    child: DefaultTextStyle(
                      style: TextStyle(
                        color: Theme.of(dialogCtx).colorScheme.onSurface,
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(
                                  sigmaX: 12 * curved.value,
                                  sigmaY: 12 * curved.value,
                                ),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Theme.of(
                                      dialogCtx,
                                    ).colorScheme.surface.withAlpha(200),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Padding(
                            padding: contentPadding,
                            child: Material(
                              type: MaterialType.transparency,
                              child: builder(dialogCtx),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget getButton(
  Widget text,
  Function()? onPressed,
  Color accent, {
  Color? disabled,
  EdgeInsets? padding,
  double? radius,
  bool minimumSize = false,
  bool filled = false,
}) => TextButton(
  style: ButtonStyle(
    minimumSize: minimumSize
        ? const WidgetStatePropertyAll(Size.zero)
        : const WidgetStatePropertyAll(null),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    backgroundColor: WidgetStatePropertyAll(
      filled ? accent : Colors.transparent,
    ),
    foregroundColor: WidgetStatePropertyAll(
      onPressed == null && disabled != null
          ? disabled
          : filled
          ? readableOn(accent)
          : accent,
    ),
    padding: WidgetStatePropertyAll(
      padding ?? EdgeInsets.symmetric(horizontal: 15),
    ),
    overlayColor: WidgetStatePropertyAll(
      (onPressed == null && disabled != null ? disabled : accent).withAlpha(50),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(
        side: BorderSide(
          width: 1.5,
          color: onPressed == null && disabled != null ? disabled : accent,
        ),
        borderRadius: BorderRadius.circular(radius ?? 30),
      ),
    ),
  ),

  onPressed: onPressed,
  child: text,
);

class TimedButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final Color accent;
  final Color? disabled;
  final Color? disabled2;
  final Duration duration;

  const TimedButton({
    super.key,
    required this.child,
    required this.onPressed,
    required this.accent,
    this.disabled,
    this.disabled2,
    required this.duration,
  });

  @override
  State<TimedButton> createState() => _TimedButtonState();
}

class _TimedButtonState extends State<TimedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      ..forward()
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) setState(() => _ready = true);
      });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    final col = _ready
        ? widget.accent
        : (widget.disabled ?? widget.accent.withAlpha(80));
    final col2 = _ready
        ? widget.accent
        : (widget.disabled2 ?? widget.accent.withAlpha(80));

    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) => ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: LinearProgressIndicator(
                value: _ctrl.value,
                backgroundColor: Colors.transparent,
                color: widget.accent.withAlpha(50),
                minHeight: double.infinity,
              ),
            ),
          ),
        ),

        Padding(
          padding: isDesktop ? .zero : .symmetric(horizontal: 5), // ts pmo
          child: TextButton(
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(col2),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 15),
              ),
              overlayColor: WidgetStatePropertyAll(col.withAlpha(50)),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  side: BorderSide(width: 1.5, color: col),
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            onPressed: _ready ? widget.onPressed : null,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}

enum NoticeDialogType { info, warning, error, none }

Future<void> showNoticeDialog({
  required BuildContext context,
  required NoticeDialogType type,
  required String title,
  String? subtitle,
  Widget? children,
  Color? buttonColor,
  String? dismissText = "OK",
  bool? isTimedButton = false,
  List<Widget> Function(BuildContext)? buildButtons,
}) {
  return showScaleDialog<void>(
    context: context,
    builder: (dialogCtx) {
      final cs = Theme.of(dialogCtx).colorScheme;
      final nav = Navigator.of(dialogCtx);

      final (IconData icon, Color accent) = switch (type) {
        NoticeDialogType.info => (Icons.info_outline, cs.primary),
        NoticeDialogType.warning => (Icons.warning_amber_rounded, cs.primary),
        NoticeDialogType.error => (Icons.error_outline, cs.primary),
        _ => (Icons.error_outline, cs.primary),
      };

      return Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            if (type != NoticeDialogType.none)
              Icon(icon, size: 34, color: accent),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontFamily: "Syne",
                color: cs.onSurface,
                fontVariations: const [
                  FontVariation('wdth', 2800),
                  FontVariation('wght', 700),
                ],
              ),
            ),
            if (subtitle != null && subtitle.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                subtitle,
                textAlign: TextAlign.start,
                style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
              ),
            ],
            if (children != null) ...[children], // lmfao
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: 12,
              children: [
                if (buildButtons != null) ...buildButtons(dialogCtx),
                if (isTimedButton ?? false)
                  TimedButton(
                    onPressed: () => nav.pop(),
                    accent: buttonColor ?? accent,
                    duration: Duration(seconds: 3),
                    child: Text(dismissText ?? "OK"),
                  )
                else
                  getButton(
                    Text(dismissText ?? "OK"),
                    () => nav.pop(),
                    buttonColor ?? accent,
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
