import 'package:flutter/material.dart';

import '../student_surface.dart';
import 'common.dart';

typedef _Question = (String, String);

const _questions = <_Question>[
  ('最近，晚上想睡时还会在脑子里想事情吗？', '睡眠'),
  ('最近，醒来后还觉得很累吗？', '睡眠'),
  ('最近，开始做一件小事也需要攒很久的力气吗？', '日常'),
  ('最近，身边的安排会让你有点喘不过气吗？', '压力'),
  ('最近，担心的事会反复冒出来吗？', '压力'),
  ('最近，本来想做的事会提不起兴趣吗？', '日常'),
  ('最近，想有个可以说说话的人吗？', '陪伴'),
  ('最近，会感觉留给自己的安静时间太少吗？', '陪伴'),
];

const _followUps = <String, _Question>{
  '睡眠': ('睡前，你还会把手机拿起来多看一会儿吗？', '睡眠'),
  '压力': ('打算休息时，也常常会想起还没做完的事吗？', '压力'),
};

class CheckInQuestionsPage extends StatefulWidget {
  const CheckInQuestionsPage({super.key});

  @override
  State<CheckInQuestionsPage> createState() => _CheckInQuestionsPageState();
}

class _CheckInQuestionsPageState extends State<CheckInQuestionsPage> {
  final _path = [..._questions];
  final _answers = <(_Question, int)>[];
  bool _started = false;

  void _answer(int value) {
    final index = _answers.length;
    final question = _path[index];
    setState(() {
      _answers.add((question, value));
      final followUp = _followUps[question.$2];
      if (value == 2 && followUp != null && !_path.contains(followUp)) {
        _path.insert(index + 1, followUp);
      }
    });
  }

  (String, String) _result() {
    final byTopic = <String, int>{};
    for (final (question, answer) in _answers) {
      if (answer == 2) {
        byTopic.update(question.$2, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    final topics = byTopic.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return switch (topics.firstOrNull?.key) {
      '睡眠' => ('最近有点需要好好歇一歇', '今晚睡前把手机搁在手够不到的地方，听一会儿喜欢的声音。'),
      '压力' => ('最近心里装了不少事', '挑一件最占心思的小事写下来，然后只想一想它的第一步。'),
      '陪伴' => ('最近也许想要一点陪伴', '给一个认识的人发一句「今天怎么样」就好。'),
      '日常' => ('最近日常有点费力', '给自己倒杯水，到窗边站一分钟。'),
      _ => ('最近有一些自己的节奏', '想一想今天哪一个小瞬间值得记下来。'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final index = _answers.length;
    final completed = index == _path.length;
    return WellbeingPage(
      title: '测一测',
      children: [
        if (!_started) ...[
          const WellbeingIntro('看看最近的自己', '用 8 到 10 个小问题回顾近况，结果仅供自己参考。'),
          StudentCard(
            child: Text(
              '按最近一周的感受回答就好。答案只在这一页使用。',
              style: theme.textTheme.bodyLarge,
            ),
          ),
          FilledButton(
            onPressed: () => setState(() => _started = true),
            child: const Text('开始'),
          ),
        ] else if (completed) ...[
          const WellbeingIntro('最近的状态', '留意到自己的感受，已经很好。'),
          StudentCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_result().$1, style: theme.textTheme.titleLarge),
                const SizedBox(height: 10),
                Text(_result().$2),
              ],
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ] else ...[
          Text('第 ${index + 1} 题', style: theme.textTheme.labelMedium),
          LinearProgressIndicator(value: index / _path.length),
          StudentCard(
            child: Text(_path[index].$1, style: theme.textTheme.titleLarge),
          ),
          for (final (value, label) in const ['很少', '有时', '经常'].indexed)
            OutlinedButton(onPressed: () => _answer(value), child: Text(label)),
        ],
      ],
    );
  }
}
