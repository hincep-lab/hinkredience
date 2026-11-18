import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/cook_timer.dart';
import '../../core/material.dart';
import '../../core/quick_timers.dart';
import '../../core/widgets.dart';
import '../cooking/cooking_screen.dart' show formatCountdown;

/// Kuchyňská minutka: hotové časy (vejce, těstoviny, rýže…), vlastní čas
/// a víc minutek naráz. Zvoní kdekoli v aplikaci.
class TimerScreen extends ConsumerStatefulWidget {
  const TimerScreen({super.key});

  @override
  ConsumerState<TimerScreen> createState() => _TimerScreenState();
}

class _TimerScreenState extends ConsumerState<TimerScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  QuickTimers get _timers => ref.read(quickTimersProvider.notifier);

  Future<void> _start(String label, Duration duration) async {
    await _timers.start(label, duration);
    if (mounted) showMessage(context, 'Minutka běží: $label');
  }

  Future<void> _custom() async {
    final name = TextEditingController();
    var minutes = 5;
    var seconds = 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: const Text('Vlastní minutka'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Na co (nepovinné)',
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _Spinner(
                    value: minutes,
                    max: 600,
                    step: 1,
                    suffix: 'min',
                    onChanged: (v) => setDialog(() => minutes = v),
                  ),
                  const SizedBox(width: 12),
                  _Spinner(
                    value: seconds,
                    max: 55,
                    step: 5,
                    suffix: 's',
                    onChanged: (v) => setDialog(() => seconds = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  for (final m in const [1, 3, 15, 30, 60])
                    ActionChip(
                      label: Text('$m min'),
                      onPressed: () => setDialog(() {
                        minutes = m;
                        seconds = 0;
                      }),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Zrušit'),
            ),
            FilledButton(
              onPressed: minutes == 0 && seconds == 0
                  ? null
                  : () => Navigator.of(context).pop(true),
              child: const Text('Spustit'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final label = name.text.trim().isEmpty ? 'Minutka' : name.text.trim();
    await _start(label, Duration(minutes: minutes, seconds: seconds));
  }

  @override
  Widget build(BuildContext context) {
    final timers = ref.watch(quickTimersProvider);
    final now = DateTime.now().toUtc();
    return Scaffold(
      appBar: AppBar(title: const Text('Minutka')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'custom-timer',
        onPressed: _custom,
        icon: const Icon(Icons.more_time_rounded),
        label: const Text('Vlastní čas'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          if (timers.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                'Minutka zazvoní na kterékoli obrazovce aplikace. Na Androidu '
                'i se zhasnutým displejem.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
          for (final t in timers) _RunningTimer(timer: t, now: now),
          const SectionTitle('Rychlý start'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 2.2,
            children: [
              for (final (name, minutes, hint) in timerPresets)
                HkCard(
                  onTap: () => _start(name, Duration(minutes: minutes)),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '$minutes min · $hint',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunningTimer extends ConsumerWidget {
  const _RunningTimer({required this.timer, required this.now});

  final CookTimer timer;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timers = ref.read(quickTimersProvider.notifier);
    final done = timer.isDone(now);
    final total = timer.durationSeconds;
    final left = timer.remaining(now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: HkCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        timer.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        done ? 'Hotovo!' : formatCountdown(left),
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          color: done
                              ? AppColors.success
                              : AppColors.copperGold,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                if (!done)
                  IconButton(
                    tooltip: timer.isRunning ? 'Pozastavit' : 'Pokračovat',
                    iconSize: 32,
                    onPressed: () => timer.isRunning
                        ? timers.pause(timer)
                        : timers.resume(timer),
                    icon: Icon(
                      timer.isRunning
                          ? Icons.pause_circle_outline_rounded
                          : Icons.play_circle_outline_rounded,
                    ),
                  ),
                IconButton(
                  tooltip: done ? 'Hotovo' : 'Zrušit',
                  iconSize: 30,
                  onPressed: () => timers.stop(timer),
                  icon: Icon(
                    done ? Icons.check_circle_rounded : Icons.close_rounded,
                  ),
                ),
              ],
            ),
            if (!done && total > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 8),
                child: LinearProgressIndicator(value: 1 - left / total),
              ),
          ],
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner({
    required this.value,
    required this.max,
    required this.step,
    required this.suffix,
    required this.onChanged,
  });

  final int value;
  final int max;
  final int step;
  final String suffix;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        IconButton(
          tooltip: 'Přidat',
          onPressed: value + step > max ? null : () => onChanged(value + step),
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        ),
        Text(
          '$value $suffix',
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        IconButton(
          tooltip: 'Ubrat',
          onPressed: value - step < 0 ? null : () => onChanged(value - step),
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        ),
      ],
    );
  }
}
