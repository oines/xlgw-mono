import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/design.dart';
import '../student_surface.dart';
import 'breathing.dart';
import 'common.dart';

Future<void> initializeWellbeingAudio() async {
  if (kIsWeb ||
      !{
        TargetPlatform.android,
        TargetPlatform.iOS,
      }.contains(defaultTargetPlatform)) {
    return;
  }
  await JustAudioBackground.init(
    androidNotificationChannelId: 'dev.oines.xlgw.wellbeing.audio',
    androidNotificationChannelName: '心灵港湾音频',
    androidNotificationOngoing: true,
  );
}

enum WellbeingSound {
  rain('雨夜', '窗外的柔和雨声', Icons.water_drop_outlined, 'rain'),
  library('自习室', '低低的空间底噪', Icons.menu_book_outlined, 'library'),
  sea('海边', '潮水起落的节奏', Icons.waves_outlined, 'sea'),
  sleep('渐弱雨声', '最后两分钟会慢慢变轻', Icons.nights_stay_outlined, 'sleep');

  const WellbeingSound(this.title, this.description, this.icon, this.file);

  final String title;
  final String description;
  final IconData icon;
  final String file;
}

const _librarySounds = [
  WellbeingSound.rain,
  WellbeingSound.library,
  WellbeingSound.sea,
];

final _soundPreferences = SharedPreferencesAsync();

String _favoritesKey(String accountId) =>
    'harbor.wellbeing.sound.favorites.$accountId';

Future<Set<String>> getSoundFavorites(String accountId) async {
  if (accountId.isEmpty) return {};
  final saved =
      await _soundPreferences.getStringList(_favoritesKey(accountId)) ?? [];
  return {
    for (final sound in _librarySounds)
      if (saved.contains(sound.file)) sound.file,
  };
}

final _player = _createPlayer();

AudioPlayer _createPlayer() {
  final player = AudioPlayer();
  player.processingStateStream.listen((state) {
    if (state == ProcessingState.completed) unawaited(player.stop());
  });
  return player;
}

class SoundLibraryPage extends StatefulWidget {
  const SoundLibraryPage({
    required this.accountId,
    this.favoritesOnly = false,
    super.key,
  });

  final String accountId;
  final bool favoritesOnly;

  @override
  State<SoundLibraryPage> createState() => _SoundLibraryPageState();
}

class _SoundLibraryPageState extends State<SoundLibraryPage> {
  WellbeingSound? _selected;
  int _minutes = 10;
  bool _saving = false;
  late Future<Set<String>> _favorites = getSoundFavorites(widget.accountId);

  @override
  void didUpdateWidget(covariant SoundLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.accountId != widget.accountId) {
      _favorites = getSoundFavorites(widget.accountId);
      _selected = null;
    }
  }

  void _reload() =>
      setState(() => _favorites = getSoundFavorites(widget.accountId));

  Future<void> _toggleFavorite(
    WellbeingSound sound,
    Set<String> current,
  ) async {
    final accountId = widget.accountId;
    final updated = {...current};
    if (!updated.remove(sound.file)) updated.add(sound.file);
    setState(() => _saving = true);
    try {
      await _soundPreferences.setStringList(
        _favoritesKey(accountId),
        updated.toList(),
      );
      if (mounted && widget.accountId == accountId) {
        setState(() => _favorites = Future.value(updated));
      }
    } catch (_) {
      if (mounted) flash(context, '暂时无法保存收藏，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Set<String>>(
    key: ValueKey(widget.accountId),
    future: _favorites,
    builder: (context, snapshot) {
      final favorites = snapshot.data;
      final sounds = _librarySounds
          .where(
            (sound) =>
                !widget.favoritesOnly ||
                (favorites?.contains(sound.file) ?? false),
          )
          .toList();
      final sound = sounds.contains(_selected) ? _selected : sounds.firstOrNull;
      return WellbeingPage(
        title: widget.favoritesOnly ? '收藏的音频' : '轻松听',
        children: [
          if (!widget.favoritesOnly)
            const WellbeingIntro('听一段声音就好', '选个声音和时长，想放下手机也可以。'),
          if (snapshot.hasError)
            LoadError('暂时无法读取收藏', _reload)
          else if (favorites == null)
            const Center(child: CircularProgressIndicator())
          else if (sound == null)
            Empty(
              '还没有收藏的声音',
              icon: Icons.favorite_border_rounded,
              action: OutlinedButton(
                onPressed: () async {
                  await open(
                    context,
                    SoundLibraryPage(accountId: widget.accountId),
                  );
                  if (mounted) _reload();
                },
                child: const Text('去声音库'),
              ),
            )
          else ...[
            StudentFilters(
              options: sounds.map((item) => item.title).toList(),
              selected: sound.title,
              onSelect: (title) => setState(() {
                _selected = sounds.firstWhere((item) => item.title == title);
              }),
            ),
            if (widget.accountId.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _saving
                      ? null
                      : () => _toggleFavorite(sound, favorites),
                  icon: Icon(
                    favorites.contains(sound.file)
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                  ),
                  label: Text(
                    favorites.contains(sound.file) ? '取消收藏' : '收藏这段声音',
                  ),
                ),
              ),
            StudentFilters(
              options: const ['10 分钟', '20 分钟', '30 分钟'],
              selected: '$_minutes 分钟',
              onSelect: (value) =>
                  setState(() => _minutes = int.parse(value.split(' ').first)),
            ),
            SoundPlayback(sound: sound, minutes: _minutes),
          ],
        ],
      );
    },
  );
}

class SoundPlayback extends StatefulWidget {
  const SoundPlayback({
    required this.sound,
    required this.minutes,
    this.breathing = false,
    super.key,
  });

  final WellbeingSound sound;
  final int minutes;
  final bool breathing;

  @override
  State<SoundPlayback> createState() => _SoundPlaybackState();
}

class _SoundPlaybackState extends State<SoundPlayback> {
  bool _loading = false;

  String get _id => '${widget.sound.file}-${widget.minutes}';

  Future<void> _toggle(bool same, bool playing) async {
    setState(() => _loading = true);
    try {
      if (same && playing) {
        await _player.pause();
      } else {
        if (!same || _player.processingState == ProcessingState.idle) {
          final duration = Duration(minutes: widget.minutes);
          final item = MediaItem(
            id: _id,
            album: '心灵港湾',
            title: widget.sound.title,
            duration: duration,
          );
          final source = AudioSource.asset(
            'assets/wellbeing/${widget.sound.file}.mp3',
            tag: item,
          );
          await _player.setAudioSource(
            ClippingAudioSource(child: source, end: duration, tag: item),
          );
        } else if (_player.processingState == ProcessingState.completed) {
          await _player.seek(Duration.zero);
        }
        unawaited(
          _player.play().catchError((Object error) {
            if (mounted) flash(context, '暂时无法播放，请再试一次');
          }),
        );
      }
    } catch (error) {
      if (mounted) flash(context, '暂时无法播放，请再试一次');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: _player.playerStateStream,
      initialData: _player.playerState,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final item = _player.sequenceState.currentSource?.tag;
        final same = item is MediaItem && item.id == _id;
        final playable =
            same &&
            state.processingState != ProcessingState.idle &&
            state.processingState != ProcessingState.completed;
        final otherPlaying = !same && state.playing;
        final playing = playable && state.playing;
        final label = playing ? '暂停' : (playable ? '继续播放' : '播放');
        final theme = Theme.of(context);
        return StudentCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Icon(widget.sound.icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.sound.title,
                          style: theme.textTheme.titleMedium,
                        ),
                        Text(widget.sound.description),
                      ],
                    ),
                  ),
                  Text(
                    '${widget.minutes} 分钟',
                    style: theme.textTheme.labelMedium,
                  ),
                ],
              ),
              if (playable)
                StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  initialData: _player.position,
                  builder: (context, snapshot) {
                    final position = snapshot.data ?? Duration.zero;
                    final total = widget.minutes * 60;
                    return Column(
                      children: [
                        if (widget.breathing &&
                            position < breathingPracticeDuration)
                          BreathingCue(
                            pattern: BreathingPattern.slow,
                            elapsed: position,
                            active: true,
                          ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: (position.inSeconds / total).clamp(0.0, 1.0),
                        ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: _loading ? null : () => _toggle(same, playing),
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(_loading ? '正在准备…' : label),
              ),
              if (playable || otherPlaying)
                TextButton(
                  onPressed: _loading ? null : _player.stop,
                  child: Text(otherPlaying ? '结束当前播放' : '结束播放'),
                ),
            ],
          ),
        );
      },
    );
  }
}
