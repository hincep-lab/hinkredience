import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/cooking_services.dart';
import '../../core/formatters.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/recipe_time.dart';
import '../../core/screen_wake.dart';
import '../../core/voice_commands.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';

/// mm:ss nebo h:mm:ss.
String formatCountdown(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// Navržená délka časovače pro krok (z délky kroku, jinak z textu postupu).
int? suggestedTimerMinutes(RecipeStep step) {
  if (step.durationMinutes != null && step.durationMinutes! > 0) {
    return step.durationMinutes;
  }
  final parsed = parseStepText(step.instruction);
  final total = parsed.passive + parsed.cook;
  return total > 0 ? total : null;
}

/// Režim „Vaříme spolu“: postup krok za krokem s velkým písmem, časovači,
/// upozorněním, předčítáním a hlasovými povely. Stav se průběžně ukládá,
/// takže po zavření aplikace jde ve vaření pokračovat.
class CookingScreen extends ConsumerStatefulWidget {
  const CookingScreen({super.key, required this.recipeId, this.servings});

  final String recipeId;
  final double? servings;

  @override
  ConsumerState<CookingScreen> createState() => _CookingScreenState();
}

class _CookingScreenState extends ConsumerState<CookingScreen> {
  CookingSession? _session;
  Timer? _ticker;
  final _rung = <String>{};
  bool _readAloud = false;
  bool _listening = false;
  bool _askedPermission = false;
  String? _heard;

  CookAlerts get _alerts => ref.read(cookAlertsProvider);

  @override
  void initState() {
    super.initState();
    _start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    ref.read(speakerProvider).stop();
    ref.read(voiceInputProvider).stop();
    super.dispose();
  }

  Future<Recipe?> _recipe() async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    return repository.getById(widget.recipeId);
  }

  Future<void> _start() async {
    final docs = await ref.read(docsRepositoryProvider.future);
    final recipe = await _recipe();
    if (recipe == null || !mounted) return;
    var open = await docs.openSession();
    if (open != null && open.recipeId != recipe.id && mounted) {
      final keep = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Rozvařený jiný recept'),
          content: Text(
            'Právě vaříte „${open!.recipeTitle}“. Chcete v něm pokračovat, '
            'nebo ho ukončit bez zápisu a začít „${recipe.title}“?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Pokračovat v něm'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Začít nový'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (keep == true && open.recipeId != null) {
        context.pushReplacement(Routes.cook(open.recipeId!));
        return;
      }
      for (final timer in open.timers) {
        await _alerts.cancel(timer);
      }
      await docs.deleteSession(open.id);
      open = null;
    }
    final now = docs.now();
    final session =
        open ??
        await docs.saveSession(
          CookingSession(
            id: docs.newId(),
            recipeId: recipe.id,
            recipeTitle: recipe.title,
            versionNumber: recipe.currentVersion,
            status: SessionStatus.inProgress,
            servings: widget.servings ?? recipe.servings,
            cookedAt: now,
            updatedAt: now,
            resumedAt: now,
          ),
        );
    if (!mounted) return;
    setState(() => _session = session);
  }

  Future<void> _update(CookingSession Function(CookingSession) change) async {
    final current = _session;
    if (current == null) return;
    final next = change(current);
    setState(() => _session = next);
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.saveSession(next);
  }

  void _tick() {
    final session = _session;
    if (session == null || !mounted) return;
    final now = DateTime.now().toUtc();
    for (final timer in session.timers) {
      if (timer.isDone(now) && !timer.acknowledged && _rung.add(timer.id)) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
        if (_readAloud) {
          ref.read(speakerProvider).say('Časovač doběhl. ${timer.label}');
        }
      }
    }
    setState(() {});
  }

  // -------------------------------------------------------------- kroky

  void _goTo(int index, Recipe recipe) {
    final clamped = index.clamp(
      0,
      recipe.steps.isEmpty ? 0 : recipe.steps.length - 1,
    );
    _update((s) => s.copyWith(stepIndex: clamped));
    if (_readAloud && recipe.steps.isNotEmpty) {
      _readStep(recipe, clamped);
    }
  }

  void _readStep(Recipe recipe, int index) {
    if (recipe.steps.isEmpty) return;
    final step = recipe.steps[index];
    ref
        .read(speakerProvider)
        .say(
          'Krok ${index + 1}. ${step.instruction}'
          '${step.temperatureC == null ? '' : ' Teplota ${formatQuantity(step.temperatureC!)} stupňů.'}',
        );
  }

  // ------------------------------------------------------------ časovače

  Future<void> _startTimer(Recipe recipe, {int? minutes}) async {
    final session = _session;
    if (session == null) return;
    final index = session.stepIndex;
    final step = recipe.steps.isEmpty ? null : recipe.steps[index];
    var length = minutes ?? (step == null ? null : suggestedTimerMinutes(step));
    length ??= await _askMinutes();
    if (length == null || length <= 0 || !mounted) return;
    if (!_askedPermission) {
      _askedPermission = true;
      await _alerts.requestPermission();
    }
    final now = DateTime.now().toUtc();
    final label = step == null
        ? recipe.title
        : 'Krok ${index + 1}: ${_short(step.instruction)}';
    final timers = CookTimers(session.timers).start(
      id: 'k$index-${now.millisecondsSinceEpoch}',
      label: label,
      duration: Duration(minutes: length),
      now: now,
      stepIndex: step == null ? null : index,
    );
    final started = timers.timers.last;
    await _update((s) => s.copyWith(timers: timers.timers));
    await _alerts.schedule(started);
  }

  static String _short(String text) =>
      text.length <= 40 ? text : '${text.substring(0, 38).trimRight()}…';

  Future<int?> _askMinutes() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Časovač'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Počet minut'),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zrušit'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Spustit'),
          ),
        ],
      ),
    );
    return int.tryParse((text ?? '').trim());
  }

  Future<void> _timerAction(CookTimer timer, String action) async {
    final session = _session;
    if (session == null) return;
    final now = DateTime.now().toUtc();
    final timers = CookTimers(session.timers);
    switch (action) {
      case 'pause':
        await _alerts.cancel(timer);
        await _update(
          (s) => s.copyWith(
            timers: timers.update(timer.id, (t) => t.pause(now)).timers,
          ),
        );
      case 'resume':
        final updated = timers.update(timer.id, (t) => t.resume(now));
        await _update((s) => s.copyWith(timers: updated.timers));
        await _alerts.schedule(
          updated.timers.firstWhere((t) => t.id == timer.id),
        );
      case 'ok':
      case 'remove':
        await _alerts.cancel(timer);
        await _update(
          (s) => s.copyWith(timers: timers.remove(timer.id).timers),
        );
    }
  }

  // ------------------------------------------------------- pauza, konec

  Future<void> _togglePause() async {
    final session = _session;
    if (session == null) return;
    final now = DateTime.now().toUtc();
    if (session.status == SessionStatus.paused) {
      final timers = [
        for (final t in session.timers) t.isRunning ? t : t.resume(now),
      ];
      await _update(
        (s) => s.copyWith(
          status: SessionStatus.inProgress,
          resumedAt: now,
          timers: timers,
        ),
      );
      for (final t in timers) {
        await _alerts.schedule(t);
      }
    } else {
      for (final t in session.timers) {
        await _alerts.cancel(t);
      }
      await _update(
        (s) => s.copyWith(
          status: SessionStatus.paused,
          activeSeconds: s.elapsedSeconds(now),
          resumedAt: null,
          timers: [for (final t in s.timers) t.pause(now)],
        ),
      );
    }
  }

  Future<void> _finish() async {
    final session = _session;
    if (session == null) return;
    for (final t in session.timers) {
      await _alerts.cancel(t);
    }
    final now = DateTime.now().toUtc();
    await _update(
      (s) => s.copyWith(
        activeSeconds: s.elapsedSeconds(now),
        resumedAt: null,
        status: SessionStatus.paused,
        timers: const [],
      ),
    );
    if (mounted) context.pushReplacement(Routes.diaryEntry(session.id));
  }

  Future<void> _cancel() async {
    final session = _session;
    if (session == null) return;
    final ok = await confirm(
      context,
      title: 'Ukončit bez zápisu?',
      message: 'Vaření se ukončí a do deníku se nic neuloží.',
      confirmLabel: 'Ukončit',
      destructive: true,
    );
    if (!ok) return;
    for (final t in session.timers) {
      await _alerts.cancel(t);
    }
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.deleteSession(session.id);
    if (mounted) context.pop();
  }

  // ------------------------------------------------------------- hlas

  Future<void> _listen(Recipe recipe) async {
    setState(() {
      _listening = true;
      _heard = null;
    });
    final ok = await ref.read(voiceInputProvider).listen((words) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _heard = words;
      });
      _runCommand(parseVoiceCommand(words), recipe);
    });
    if (!ok && mounted) {
      setState(() => _listening = false);
      showMessage(
        context,
        'Rozpoznávání hlasu není v telefonu dostupné nebo povolené.',
      );
    }
    // Poslech skončí sám po pár vteřinách ticha.
    Future<void>.delayed(const Duration(seconds: 9), () {
      if (mounted && _listening) setState(() => _listening = false);
    });
  }

  void _runCommand(VoiceCommand? command, Recipe recipe) {
    final session = _session;
    if (session == null) return;
    switch (command) {
      case VoiceCommand.next:
        if (session.stepIndex >= recipe.steps.length - 1) {
          _finish();
        } else {
          _goTo(session.stepIndex + 1, recipe);
        }
      case VoiceCommand.previous:
        _goTo(session.stepIndex - 1, recipe);
      case VoiceCommand.repeat:
        _readStep(recipe, session.stepIndex);
      case VoiceCommand.timer:
        _startTimer(recipe);
      case VoiceCommand.pause:
        if (session.status != SessionStatus.paused) _togglePause();
      case VoiceCommand.resume:
        if (session.status == SessionStatus.paused) _togglePause();
      case VoiceCommand.ingredients:
        _showIngredients(recipe);
      case VoiceCommand.finish:
        _finish();
      case null:
        showMessage(
          context,
          'Nerozuměl jsem. Zkuste „další“, „zpět“, „časovač“.',
        );
    }
  }

  void _showIngredients(Recipe recipe) {
    final servings = _session?.servings ?? recipe.servings;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            children: [
              Text(
                'Suroviny (${yieldLabel(servings, recipe.yieldUnit)})',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              for (final item in recipe.ingredients)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          item.nameLabel(
                            fromServings: recipe.servings,
                            toServings: servings,
                          ),
                          style: const TextStyle(fontSize: 19),
                        ),
                      ),
                      Text(
                        item.amountLabel(
                          fromServings: recipe.servings,
                          toServings: servings,
                        ),
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: AppColors.copperGold,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- vzhled

  @override
  Widget build(BuildContext context) {
    final recipe = ref.watch(recipeProvider(widget.recipeId)).value;
    final session = _session;
    return KeepScreenOn(
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            recipe?.title ?? 'Vaříme spolu',
            overflow: TextOverflow.ellipsis,
          ),
          actions: recipe == null || session == null
              ? null
              : [
                  IconButton(
                    tooltip: _readAloud
                        ? 'Nepředčítat kroky'
                        : 'Předčítat kroky',
                    icon: Icon(
                      _readAloud
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_outlined,
                    ),
                    onPressed: () {
                      setState(() => _readAloud = !_readAloud);
                      if (_readAloud) {
                        _readStep(recipe, session.stepIndex);
                      } else {
                        ref.read(speakerProvider).stop();
                      }
                    },
                  ),
                  IconButton(
                    tooltip: 'Suroviny',
                    icon: const Icon(Icons.format_list_bulleted_rounded),
                    onPressed: () => _showIngredients(recipe),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Další možnosti',
                    onSelected: (value) =>
                        value == 'cancel' ? _cancel() : _finish(),
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'finish',
                        child: Text('Dokončit a zapsat'),
                      ),
                      PopupMenuItem(
                        value: 'cancel',
                        child: Text(
                          'Ukončit bez zápisu',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ),
                    ],
                  ),
                ],
        ),
        body: recipe == null || session == null
            ? const Center(child: CircularProgressIndicator())
            : _body(recipe, session),
      ),
    );
  }

  Widget _body(Recipe recipe, CookingSession session) {
    final now = DateTime.now().toUtc();
    final steps = recipe.steps;
    final index = steps.isEmpty
        ? 0
        : session.stepIndex.clamp(0, steps.length - 1);
    final step = steps.isEmpty ? null : steps[index];
    final last = steps.isEmpty || index == steps.length - 1;
    final paused = session.status == SessionStatus.paused;
    final ringing = CookTimers(session.timers).ringing(now);
    final suggested = step == null ? null : suggestedTimerMinutes(step);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(
          value: steps.isEmpty ? 1 : (index + 1) / steps.length,
          minHeight: 4,
        ),
        for (final timer in ringing)
          MaterialBanner(
            backgroundColor: AppColors.copper,
            leading: const Icon(
              Icons.alarm_rounded,
              color: Color(0xFF1B1108),
              size: 32,
            ),
            content: Text(
              'Doběhlo: ${timer.label}',
              style: const TextStyle(
                color: Color(0xFF1B1108),
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => _timerAction(timer, 'ok'),
                child: const Text(
                  'OK',
                  style: TextStyle(color: Color(0xFF1B1108), fontSize: 18),
                ),
              ),
            ],
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      steps.isEmpty
                          ? 'Recept nemá postup'
                          : 'Krok ${index + 1} z ${steps.length}',
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  Icon(
                    paused
                        ? Icons.pause_circle_outline_rounded
                        : Icons.timer_outlined,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${paused ? 'Pozastaveno · ' : ''}${formatCountdown(session.elapsedSeconds(now))}',
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                step?.instruction ?? 'Postup doplníte v úpravě receptu. Vaření můžete i tak zapsat do deníku.',
                style: const TextStyle(
                  fontSize: 26,
                  height: 1.4,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (step?.temperatureC != null)
                    Chip(
                      avatar: const Icon(Icons.thermostat_rounded),
                      label: Text(
                        '${formatQuantity(step!.temperatureC!)} °C',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  if (step?.durationMinutes != null)
                    Chip(
                      avatar: const Icon(Icons.schedule_rounded),
                      label: Text(
                        formatMinutes(step!.durationMinutes!),
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  for (final t in recipe.temperatures)
                    if (step?.temperatureC == null) Chip(label: Text(t)),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: paused ? null : () => _startTimer(recipe),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                ),
                icon: const Icon(Icons.alarm_add_rounded, size: 26),
                label: Text(
                  suggested == null
                      ? 'Spustit časovač'
                      : 'Spustit časovač ${formatMinutes(suggested)}',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              if (session.timers.isNotEmpty) ...[
                const SizedBox(height: 16),
                for (final timer in session.timers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: HkCard(
                      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                      child: Row(
                        children: [
                          Text(
                            formatCountdown(timer.remaining(now)),
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              color: timer.isDone(now)
                                  ? AppColors.copperGold
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              timer.label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!timer.isDone(now))
                            IconButton(
                              tooltip: timer.isRunning
                                  ? 'Pozastavit časovač'
                                  : 'Pokračovat',
                              icon: Icon(
                                timer.isRunning
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                              onPressed: () => _timerAction(
                                timer,
                                timer.isRunning ? 'pause' : 'resume',
                              ),
                            ),
                          IconButton(
                            tooltip: 'Zrušit časovač',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => _timerAction(timer, 'remove'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (_heard != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Slyšel jsem: „$_heard“',
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  height: 64,
                  child: OutlinedButton(
                    onPressed: index == 0
                        ? null
                        : () => _goTo(index - 1, recipe),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      size: 30,
                      semanticLabel: 'Předchozí krok',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: IconButton.filledTonal(
                    tooltip: paused
                        ? 'Pokračovat ve vaření'
                        : 'Pozastavit vaření',
                    onPressed: _togglePause,
                    icon: Icon(
                      paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: IconButton.filledTonal(
                    tooltip: 'Hlasový povel',
                    onPressed: _listening ? null : () => _listen(recipe),
                    icon: Icon(
                      _listening ? Icons.hearing_rounded : Icons.mic_rounded,
                      size: 30,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SizedBox(
                    height: 64,
                    child: FilledButton(
                      onPressed: last
                          ? _finish
                          : () => _goTo(index + 1, recipe),
                      child: Text(
                        last ? 'Dokončit' : 'Další krok',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
