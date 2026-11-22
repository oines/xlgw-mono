import 'image.dart';
import 'package:flutter/material.dart';
import '../shared/api.dart';
import '../shared/design.dart';
import 'viewport.dart';

const faceLabels = {
  'faceWidth': '脸宽',
  'faceLength': '脸长',
  'jawWidth': '下颊宽度',
  'chinLength': '下脸长度',
  'eyeSize': '眼睛大小',
  'eyeSpacing': '眼睑宽度',
  'browHeight': '耳尖厚度',
  'noseWidth': '嘴鼻宽度',
  'noseLength': '头部厚度',
  'mouthWidth': '嘴宽',
};
const presets = {
  'clear': ('团团猫', 0, 0, '#FFFFFF', '#FFFFFF', '#FFFFFF', '#6D9D89'),
  'soft': ('暖暖狐', 0, 0, '#FFFFFF', '#FFFFFF', '#FFFFFF', '#6D9D89'),
  'poised': ('咕咕鸮', 0, 0, '#FFFFFF', '#FFFFFF', '#FFFFFF', '#6D9D89'),
};
Data presetConfig(String name) {
  final p = presets[name] ?? presets['clear']!;
  return {
    'version': 1,
    'preset': name,
    'hair': p.$2,
    'outfit': p.$3,
    'skin': p.$4,
    'hairColor': p.$5,
    'eyeColor': p.$6,
    'clothColor': p.$7,
    'face': {for (final k in faceLabels.keys) k: 50},
  };
}

class AvatarEditor extends StatefulWidget {
  const AvatarEditor(this.api, {super.key, this.motion = 'standard'});
  final HarborApi api;
  final String motion;
  @override
  State<AvatarEditor> createState() => _AvatarEditorState();
}

class _AvatarEditorState extends State<AvatarEditor> {
  Data config = presetConfig('clear');
  Data? beforePreset;
  int? revision;
  int category = 0, reset = 0;
  String action = 'idle';
  bool dirty = false, busy = false, leave = false;
  Object? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => error = null);
    try {
      final result = await widget.api.request('/avatars/me');
      if (!mounted) return;
      setState(() {
        revision = result['revision'] as int;
        config = data(result['config']);
        dirty = false;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  void change(Data updates) {
    setState(() {
      config = {...config, ...updates};
      dirty = true;
    });
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      final result = await widget.api.put('/avatars/me', {
        'revision': revision,
        'config': config,
      });
      if (!mounted) return;
      setState(() {
        dirty = false;
        leave = true;
      });
      Navigator.pop(context, data(result['config']));
    } catch (e) {
      if (!mounted) return;
      if (e is ApiError && e.status == 409) {
        final reload = await confirmAction(
          context,
          '形象已在另一台设备更新',
          '重新加载后将显示最近保存的形象。可取消并继续查看当前草稿。',
          confirm: '重新加载',
        );
        if (reload && mounted) await load();
      } else {
        flash(context, e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> exit() async {
    if (dirty &&
        !await confirmAction(
          context,
          '放弃本次调整？',
          '离开后，这次尚未保存的调整会丢失。',
          confirm: '放弃调整',
        ))
      return;
    if (mounted) {
      setState(() => leave = true);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return PopScope(
      canPop: !dirty || leave,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) exit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('伙伴形象'),
          centerTitle: true,
          leading: TextButton(onPressed: exit, child: const Text('取消')),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: revision == null || busy || !dirty ? null : save,
                child: Text(busy ? '保存中' : '保存'),
              ),
            ),
          ],
        ),
        body: revision == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : LoadError(error!, load),
              )
            : SafeArea(
                child: LayoutBuilder(
                  builder: (_, box) => Column(
                    children: [
                      SizedBox(
                        height: (box.maxHeight * .44).clamp(142, 360),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CompanionView(
                                config: config,
                                state: action,
                                motion: widget.motion,
                                view: category == 1 ? 'face' : 'bust',
                                reset: reset,
                                controls: true,
                              ),
                              Positioned(
                                bottom: 8,
                                left: 8,
                                child: PopupMenuButton<String>(
                                  tooltip: '预览动作',
                                  initialValue: action,
                                  onSelected: (v) => setState(() {
                                    action = v;
                                  }),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'idle',
                                      child: Text('待机'),
                                    ),
                                    PopupMenuItem(
                                      value: 'greeting',
                                      child: Text('招手'),
                                    ),
                                    PopupMenuItem(
                                      value: 'listening',
                                      child: Text('倾听'),
                                    ),
                                    PopupMenuItem(
                                      value: 'thinking',
                                      child: Text('思考'),
                                    ),
                                    PopupMenuItem(
                                      value: 'reply',
                                      child: Text('回应'),
                                    ),
                                    PopupMenuItem(
                                      value: 'farewell',
                                      child: Text('告别'),
                                    ),
                                  ],
                                  child: Material(
                                    color: t.colorScheme.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(Icons.play_arrow_rounded),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                bottom: 8,
                                right: 8,
                                child: IconButton.filledTonal(
                                  tooltip: '回正视角',
                                  onPressed: () => setState(() => reset++),
                                  icon: const Icon(
                                    Icons.center_focus_strong_outlined,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Material(
                          color: t.colorScheme.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                          child: Column(
                            children: [
                              DefaultTabController(
                                length: 5,
                                child: TabBar(
                                  isScrollable: true,
                                  tabAlignment: TabAlignment.center,
                                  onTap: (i) => setState(() => category = i),
                                  tabs: const [
                                    Tab(text: '预设'),
                                    Tab(text: '五官'),
                                    Tab(text: '耳朵'),
                                    Tab(text: '配饰'),
                                    Tab(text: '颜色'),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: ListView(
                                  key: ValueKey(category),
                                  padding: const EdgeInsets.all(16),
                                  children: options(context),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  List<Widget> options(BuildContext context) {
    final t = Theme.of(context);
    switch (category) {
      case 0:
        return [
          partChoices([
            for (final item in presets.entries)
              tile(
                item.value.$1,
                'poster-${item.key}.png',
                config['preset'] == item.key,
                () {
                  beforePreset = config;
                  change(presetConfig(item.key));
                },
              ),
          ]),
          if (beforePreset != null)
            TextButton(
              onPressed: () {
                change(beforePreset!);
                setState(() => beforePreset = null);
              },
              child: const Text('撤销预设替换'),
            ),
        ];
      case 1:
        final face = data(config['face']);
        return [
          for (final item in faceLabels.entries)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(item.value),
                    Text(
                      '${face[item.key] ?? 50}',
                      style: t.textTheme.labelMedium,
                    ),
                  ],
                ),
                Slider(
                  value: (face[item.key] as num? ?? 50).toDouble(),
                  max: 100,
                  divisions: 100,
                  label: item.value,
                  onChanged: (v) => change({
                    'face': {...face, item.key: v.round()},
                  }),
                ),
                const SizedBox(height: 8),
              ],
            ),
        ];
      case 2:
        const names = ['原样', '短耳', '长耳', '小巧耳', '挺耳', '自然耳'];
        return [
          partChoices([
            for (var i = 0; i < 6; i++)
              tile(
                names[i],
                'thumbnails/hair-$i.png',
                config['hair'] == i,
                () => change({'hair': i}),
              ),
          ]),
        ];
      case 3:
        const names = ['无配饰', '小领结', '侧领结'];
        return [
          partChoices([
            for (var i = 0; i < 3; i++)
              tile(
                names[i],
                'thumbnails/outfit-$i.png',
                config['outfit'] == i,
                () => change({'outfit': i}),
              ),
          ]),
        ];
      default:
        return [
          colors('毛色', 'skin', const {
            '原色': '#FFFFFF',
            '暖茶': '#FFDEBA',
            '浅莓': '#FFD1E6',
            '薄荷': '#C7F2CF',
            '晴空': '#C8DAFF',
          }),
          colors('斑纹', 'hairColor', const {
            '原色': '#FFFFFF',
            '松绿': '#7EAF99',
            '肉桂': '#AA7053',
            '雾紫': '#AF9BE2',
            '蓝灰': '#8BA8CC',
          }),
          colors('眼睛', 'eyeColor', const {
            '原色': '#FFFFFF',
            '栗棕': '#D79868',
            '森林': '#67CB9B',
            '淡紫': '#D3A3F0',
          }),
          colors('配饰颜色', 'clothColor', const {
            '鼠尾草': '#9BAD8A',
            '雾蓝': '#A8C5E8',
            '燕麦': '#DFCBAC',
            '丁香': '#9D9AA9',
            '灰绿': '#668D83',
          }),
        ];
    }
  }

  Widget partChoices(List<Widget> children) => GridView.count(
    crossAxisCount: 3,
    crossAxisSpacing: 8,
    mainAxisSpacing: 8,
    childAspectRatio: .87,
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    children: children,
  );
  Widget tile(String label, String image, bool active, VoidCallback tap) {
    final t = Theme.of(context).colorScheme;
    return Material(
      color: t.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: tap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: active ? t.primary : t.outlineVariant,
              width: active ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CompanionImage(image, fit: BoxFit.cover),
                    if (active)
                      Positioned(
                        top: 5,
                        right: 5,
                        child: Icon(
                          Icons.check_circle_rounded,
                          size: 18,
                          color: t.primary,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(5),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget colors(String title, String key, Map<String, String> values) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 7,
              runSpacing: 8,
              children: values.entries.map((e) {
                final color = Color(
                  int.parse('FF' + e.value.substring(1), radix: 16),
                );
                return ChoiceChip(
                  label: Text(e.key),
                  avatar: CircleAvatar(backgroundColor: color),
                  selected: text(config, key).toUpperCase() == e.value,
                  onSelected: (_) => change({key: e.value}),
                );
              }).toList(),
            ),
          ],
        ),
      );
}
