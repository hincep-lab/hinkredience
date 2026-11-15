import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/cook_timer.dart';
import '../../core/cooking_services.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/temperatures.dart';
import '../../core/widgets.dart';
import '../cooking/cooking_screen.dart' show formatCountdown;

/// Běžící časovače spuštěné z tabulky teplot (mimo režim vaření).
class QuickTimers extends Notifier<List<CookTimer>> {
  @override
  List<CookTimer> build() => const [];

  Future<void> start(String label, int minutes) async {
    final now = DateTime.now().toUtc();
    final timer = CookTimer(
      id: 'quick-${now.microsecondsSinceEpoch}',
      label: label,
      durationSeconds: minutes * 60,
      endsAt: now.add(Duration(minutes: minutes)),
    );
    state = [...state, timer];
    final alerts = ref.read(cookAlertsProvider);
    await alerts.requestPermission();
    await alerts.schedule(timer);
  }

  Future<void> stop(CookTimer timer) async {
    state = [
      for (final t in state)
        if (t.id != timer.id) t,
    ];
    await ref.read(cookAlertsProvider).cancel(timer);
  }
}

final quickTimersProvider = NotifierProvider<QuickTimers, List<CookTimer>>(
  QuickTimers.new,
);

/// Tabulka teplot jádra a sous-vide časů s časovačem.
class TemperaturesScreen extends ConsumerStatefulWidget {
  const TemperaturesScreen({super.key});

  @override
  ConsumerState<TemperaturesScreen> createState() => _TemperaturesScreenState();
}

class _TemperaturesScreenState extends ConsumerState<TemperaturesScreen> {
  final _search = TextEditingController();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && ref.read(quickTimersProvider).isNotEmpty) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _askMinutes(String label, int? initial) async {
    final controller = TextEditingController(
      text: initial == null ? '' : '$initial',
    );
    final minutes = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Časovač'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Počet minut'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text.trim())),
            child: const Text('Spustit'),
          ),
        ],
      ),
    );
    if (minutes == null || minutes <= 0 || minutes > 5000) return;
    await _start(label, minutes);
  }

  Future<void> _start(String label, int minutes) async {
    await ref.read(quickTimersProvider.notifier).start(label, minutes);
    if (mounted) {
      showMessage(
        context,
        'Časovač běží: ${formatGuideMinutes(minutes)}. Ozve se oznámením.',
      );
    }
  }

  void _detail(TemperatureGuide guide) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(guide.name, style: Theme.of(context).textTheme.titleLarge),
              if (guide.doneness.isNotEmpty)
                Text(
                  guide.doneness,
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
              const SizedBox(height: 12),
              _Line(
                icon: Icons.thermostat_rounded,
                text: 'Teplota jádra ${guide.coreC} °C',
              ),
              if (guide.sousVideC != null)
                _Line(
                  icon: Icons.water_drop_outlined,
                  text:
                      'Sous-vide ${formatNumber(guide.sousVideC!)} °C'
                      '${guide.sousVideMinutes == null ? '' : ' · ${formatGuideMinutes(guide.sousVideMinutes!)}'}'
                      '${guide.thickness.isEmpty ? '' : ' (tloušťka ${guide.thickness})'}',
                ),
              if (guide.note.isNotEmpty)
                _Line(icon: Icons.info_outline, text: guide.note),
              const SizedBox(height: 16),
              if (guide.sousVideMinutes != null)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _start(
                      '${guide.name} – sous-vide '
                      '${formatNumber(guide.sousVideC!)} °C',
                      guide.sousVideMinutes!,
                    );
                  },
                  icon: const Icon(Icons.timer_outlined),
                  label: Text(
                    'Časovač ${formatGuideMinutes(guide.sousVideMinutes!)}',
                  ),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  _askMinutes(guide.name, guide.sousVideMinutes);
                },
                icon: const Icon(Icons.more_time_rounded),
                label: const Text('Vlastní časovač'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final timers = ref.watch(quickTimersProvider);
    final now = DateTime.now().toUtc();
    final query = foldText(_search.text.trim());
    final shown = [
      for (final guide in temperatureGuides)
        if (query.isEmpty ||
            foldText('${guide.group} ${guide.name} ${guide.doneness}')
                .contains(query))
          guide,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Teploty a sous-vide')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'quick-timer',
        onPressed: () => _askMinutes('Časovač', null),
        icon: const Icon(Icons.timer_outlined),
        label: const Text('Časovač'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          for (final timer in timers)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: HkCard(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                child: Row(
                  children: [
                    Icon(
                      timer.isDone(now)
                          ? Icons.alarm_on_rounded
                          : Icons.timer_outlined,
                      color: timer.isDone(now)
                          ? AppColors.success
                          : AppColors.copperGold,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        timer.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      timer.isDone(now)
                          ? 'Hotovo'
                          : formatCountdown(timer.remaining(now)),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AppColors.copperGold,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zrušit časovač',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () =>
                          ref.read(quickTimersProvider.notifier).stop(timer),
                    ),
                  ],
                ),
              ),
            ),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: 'Hledat (steak, kuřecí, losos…)',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Orientační hodnoty. Teplotu měřte v nejsilnějším místě, mimo kost. '
            'Sous-vide čas platí pro uvedenou tloušťku.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12.5),
          ),
          for (final group in temperatureGroups)
            if (shown.any((g) => g.group == group)) ...[
              SectionTitle(group),
              HkCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final guide in shown.where((g) => g.group == group))
                      ListTile(
                        onTap: () => _detail(guide),
                        title: Text(guide.name),
                        subtitle: Text(
                          [
                            if (guide.doneness.isNotEmpty) guide.doneness,
                            if (guide.sousVideC != null)
                              'sous-vide ${formatNumber(guide.sousVideC!)} °C'
                                  '${guide.sousVideMinutes == null ? '' : ' / ${formatGuideMinutes(guide.sousVideMinutes!)}'}',
                          ].join(' · '),
                        ),
                        trailing: Text(
                          '${guide.coreC} °C',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: AppColors.copperGold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.copperGold),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ],
    ),
  );
}
