import 'dart:ui';

import 'package:flutter/material.dart';

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
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'ok',
    barrierColor: Colors.black54,
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
      final availableWidth =
          media.size.width - effectiveInset.horizontal;
      final availableHeight =
          media.size.height - effectiveInset.vertical;
      final dialogConstraints = constraints.enforce(
        BoxConstraints(
          maxWidth: width == null
              ? availableWidth
              : width.clamp(0, availableWidth),
          maxHeight: availableHeight,
        ),
      );

      return Padding(
        padding: effectiveInset,
        child: Center(
          child: ScaleTransition(
            scale: curved,
            child: ConstrainedBox(
              constraints: dialogConstraints,
              child: DefaultTextStyle(
                style: TextStyle(color: Theme.of(dialogCtx).colorScheme.onSurface),
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
                              color: Theme.of(dialogCtx)
                                  .colorScheme
                                  .surface
                                  .withAlpha(200),
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
      );
    },
  );
}
