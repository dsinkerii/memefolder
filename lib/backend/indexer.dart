import 'package:flutter/material.dart';
import 'package:memefolder/widgets/bubble_snackbar.dart';

void indexDirectory() {
  showBubble(
    Row(
      spacing: 12,
      mainAxisSize: .min,
      children: [
        Icon(Icons.warning, color: Colors.white),
        Text(
          'not implemented!',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.none,
          ),
          softWrap: true,
        ),
      ],
    ),
  );
}
