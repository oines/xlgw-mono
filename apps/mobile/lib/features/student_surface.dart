import 'package:flutter/material.dart';

class StudentTabHeader extends StatelessWidget {
  const StudentTabHeader(this.title, {super.key, this.subtitle, this.action});

  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.headlineSmall),
              if (subtitle case final text?)
                Text(text, style: theme.textTheme.labelMedium),
            ],
          ),
        ),
        if (action case final button?) ...[const SizedBox(width: 12), button],
      ],
    );
  }
}

class StudentCard extends StatelessWidget {
  const StudentCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.color,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: color ?? Theme.of(context).colorScheme.surface,
    borderRadius: BorderRadius.circular(22),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class StudentFilters extends StatelessWidget {
  const StudentFilters({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final option in options)
          ChoiceChip(
            label: Text(option),
            selected: selected == option,
            onSelected: (_) => onSelect(option),
            showCheckmark: false,
            selectedColor: dark
                ? colors.primaryContainer
                : const Color(0xff7e9c86),
            backgroundColor: colors.surface,
            side: BorderSide(
              color: selected == option
                  ? Colors.transparent
                  : colors.outlineVariant,
            ),
            shape: const StadiumBorder(),
            labelStyle: TextStyle(
              fontSize: 12,
              color: selected == option
                  ? (dark ? colors.onPrimaryContainer : const Color(0xff14271c))
                  : colors.onSurfaceVariant,
              fontWeight: selected == option
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }
}
