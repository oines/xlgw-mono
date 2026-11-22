import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/api.dart';
import '../shared/design.dart';

class ResourcesPage extends StatefulWidget {
  const ResourcesPage(this.api, {super.key});
  final HarborApi api;
  @override
  State<ResourcesPage> createState() => _ResourcesState();
}

class _ResourcesState extends State<ResourcesPage> {
  List<Data>? list;
  Object? error;
  String kind = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final selected = kind;
    try {
      final v = await widget.api.list('/resources?kind=$selected');
      if (mounted && selected == kind)
        setState(() {
          list = v;
          error = null;
        });
    } catch (e) {
      if (mounted && selected == kind) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('校内资源')),
    body: HarborList(
      refresh: load,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final e in const [
              ('', '全部'),
              ('support', '服务'),
              ('article', '文章'),
              ('activity', '活动'),
              ('announcement', '公告'),
            ])
              ChoiceChip(
                label: Text(e.$2),
                selected: kind == e.$1,
                onSelected: (_) {
                  setState(() {
                    kind = e.$1;
                    list = null;
                    error = null;
                  });
                  load();
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (error != null) LoadError(error!, load),
        if (list == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (list?.isEmpty == true)
          const Empty(
            '这里暂时没有已发布的资源',
            icon: Icons.collections_bookmark_outlined,
          ),
        for (final v in list ?? <Data>[]) ...[
          ListTile(
            title: Text(text(v, 'title')),
            subtitle: Text(
              text(v, 'body'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(context, ResourceDetail(v)),
          ),
          const Divider(),
        ],
      ],
    ),
  );
}

class ResourceDetail extends StatelessWidget {
  const ResourceDetail(this.resource, {super.key});
  final Data resource;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('校内资源')),
    body: HarborList(
      children: [
        Text(
          text(resource, 'title'),
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        SelectableText(
          text(resource, 'body'),
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        if (text(resource, 'url').isNotEmpty) ...[
          const SizedBox(height: 18),
          OutlinedButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: const Text('打开相关链接'),
            onPressed: () async {
              if (!await launchUrl(
                    Uri.parse(text(resource, 'url')),
                    mode: LaunchMode.externalApplication,
                  ) &&
                  context.mounted)
                flash(context, '暂时无法打开该链接');
            },
          ),
        ],
      ],
    ),
  );
}
