import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

const harborInk = Color(0xff202a27);
const harborGreen = Color(0xff28665c);

ThemeData harborTheme(Brightness mode) {
  final dark = mode == Brightness.dark;
  final canvas = dark ? const Color(0xff171f1c) : const Color(0xfff5f6f3);
  final surface = dark ? const Color(0xff202b26) : Colors.white;
  final subtle = dark ? const Color(0xff26352d) : const Color(0xffeff2ed);
  final ink = dark ? const Color(0xffeaf0eb) : harborInk;
  final quiet = dark ? const Color(0xffafbbb3) : const Color(0xff61706a);
  final brand = dark ? const Color(0xffa3d3be) : harborGreen;
  final line = dark ? const Color(0xff34443b) : const Color(0xffe2e7e2);
  final danger = dark ? const Color(0xfff2aba4) : const Color(0xffb84943);
  final colors = ColorScheme.fromSeed(seedColor: brand, brightness: mode)
      .copyWith(
        primary: brand,
        onPrimary: dark ? canvas : Colors.white,
        primaryContainer: dark
            ? const Color(0xff293e34)
            : const Color(0xffe8f0eb),
        onPrimaryContainer: ink,
        surface: surface,
        onSurface: ink,
        surfaceContainerLow: canvas,
        surfaceContainer: subtle,
        onSurfaceVariant: quiet,
        outlineVariant: line,
        error: danger,
      );
  final base = ThemeData(
    colorScheme: colors,
    useMaterial3: true,
    brightness: mode,
  );
  return base.copyWith(
    scaffoldBackgroundColor: canvas,
    textTheme: base.textTheme.copyWith(
      headlineMedium: TextStyle(
        fontSize: 28,
        height: 1.3,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        height: 1.33,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 18,
        height: 1.4,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        height: 1.45,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      bodyLarge: TextStyle(fontSize: 16, height: 1.62, color: ink),
      bodyMedium: TextStyle(fontSize: 14, height: 1.55, color: ink),
      labelMedium: TextStyle(fontSize: 12, height: 1.5, color: quiet),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: canvas,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 20,
      titleTextStyle: TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
    dividerTheme: DividerThemeData(thickness: 1, space: 1, color: line),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: subtle,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: brand, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 66,
      backgroundColor: surface,
      indicatorColor: colors.primaryContainer,
      surfaceTintColor: Colors.transparent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(44, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}

String stamp(Object? raw, {bool date = false}) {
  final time = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
  return time == null
      ? ''
      : DateFormat(date ? 'M月d日 HH:mm' : 'HH:mm').format(time);
}

String stateName(Object? status) =>
    const {
      'pending': '待确认',
      'confirmed': '已确认',
      'in_progress': '服务中',
      'completed': '已完成',
      'rejected': '已拒绝',
      'canceled': '已取消',
      'expired': '已过期',
      'no_show': '未到场',
      'awaiting': '待填写',
      'pending_review': '待阅',
      'pending_contact': '待联系',
      'following': '跟进中',
      'closed': '已结束',
      'submitted': '已提交',
      'assigned': '已分配',
      'contacting': '联系中',
      'accepted': '已接受',
      'processing': '处理中',
      'resolved': '已解决',
    }[status] ??
    status?.toString() ??
    '';
String roleName(Object? role) =>
    const {
      'student': '学生',
      'teacher': '心理老师',
      'peer': '朋辈同学',
      'admin': '管理员',
    }[role] ??
    '';
String modeName(Object? mode) => mode == 'onsite' ? '线下见面' : '线上文字';

void flash(BuildContext context, Object message) {
  final bar = ScaffoldMessenger.of(context);
  bar.hideCurrentSnackBar();
  bar.showSnackBar(
    SnackBar(
      content: Text(message.toString()),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

Future<T?> open<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));

class Empty extends StatelessWidget {
  const Empty(
    this.title, {
    super.key,
    this.body,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  final String title;
  final String? body;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: t.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, color: t.colorScheme.primary),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: t.textTheme.titleMedium,
          ),
          if (body != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.colorScheme.onSurfaceVariant),
              ),
            ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 14), child: action),
        ],
      ),
    );
  }
}

class LoadError extends StatelessWidget {
  const LoadError(this.error, this.retry, {super.key});
  final Object error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => Empty(
    '暂时加载失败',
    body: error.toString(),
    icon: Icons.wifi_tethering_error_rounded,
    action: OutlinedButton(onPressed: retry, child: const Text('重试')),
  );
}

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      borderRadius: BorderRadius.circular(16),
    ),
    child: child,
  );
}

class HarborList extends StatelessWidget {
  const HarborList({
    super.key,
    required this.children,
    this.refresh,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 28),
  });
  final List<Widget> children;
  final Future<void> Function()? refresh;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: padding,
      physics: const AlwaysScrollableScrollPhysics(),
      children: children,
    );
    return refresh == null
        ? list
        : RefreshIndicator(onRefresh: refresh!, child: list);
  }
}

class PersonIcon extends StatelessWidget {
  const PersonIcon(this.name, {super.key, this.url = '', this.radius = 22});
  final String name, url;
  final double radius;
  @override
  Widget build(BuildContext context) => CircleAvatar(
    radius: radius,
    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
    foregroundImage: url.isEmpty ? null : NetworkImage(url),
    child: Text(
      name.isEmpty ? '友' : name.characters.first,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
        fontSize: radius * .7,
      ),
    ),
  );
}

Future<String?> askText(
  BuildContext context,
  String title,
  String label, {
  String initial = '',
  String confirm = '确定',
  int maxLength = 500,
  bool required = true,
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _TextDialog(title, label, initial, confirm, maxLength, required),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog(
    this.title,
    this.label,
    this.initial,
    this.confirm,
    this.maxLength,
    this.required,
  );
  final String title, label, initial, confirm;
  final int maxLength;
  final bool required;
  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final controller = TextEditingController(text: widget.initial);
  final form = GlobalKey<FormState>();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Form(
      key: form,
      child: TextFormField(
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 5,
        maxLength: widget.maxLength,
        decoration: InputDecoration(labelText: widget.label),
        validator: (v) => widget.required && (v ?? '').trim().isEmpty
            ? '请填写' + widget.label
            : null,
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate())
            Navigator.pop(context, controller.text.trim());
        },
        child: Text(widget.confirm),
      ),
    ],
  );
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String body, {
  String confirm = '确认',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;
