import 'package:flutter/material.dart';

InputDecoration newInputDeco(BuildContext context) => InputDecoration(
  filled: true,
  fillColor: Theme.of(context).colorScheme.surface,
  hintStyle: TextStyle(
    color: Theme.of(context).colorScheme.onSurface.withAlpha(160),
  ),
  prefixIconColor: Theme.of(context).colorScheme.onSurface,
  enabledBorder: OutlineInputBorder(
    borderSide: BorderSide(
      color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
      width: 1.2,
    ),
  ),
  border: const OutlineInputBorder(),
);

TextStyle newInputStyle(BuildContext context) =>
    Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: Theme.of(context).colorScheme.onSurface,
    ) ??
    TextStyle(color: Theme.of(context).colorScheme.onSurface);
