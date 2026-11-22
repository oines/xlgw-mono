import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

String wellbeingDay(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

class WellbeingPage extends StatelessWidget {
  const WellbeingPage({required this.title, required this.children, super.key});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
            children: [
              for (final (index, child) in children.indexed) ...[
                if (index > 0) const SizedBox(height: 12),
                child,
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class WellbeingIntro extends StatelessWidget {
  const WellbeingIntro(this.title, this.subtitle, {super.key});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
