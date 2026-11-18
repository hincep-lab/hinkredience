import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/formatters.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/kitchen_docs.dart';
import '../../data/recipe.dart';
import '../photos/photo_editor.dart';
import 'diary_screen.dart' show diaryDate;

/// Zápis jednoho vaření do deníku (po režimu Vaříme spolu, ručně, úprava).
class DiaryEntryScreen extends ConsumerStatefulWidget {
  const DiaryEntryScreen({super.key, required this.sessionId});

  final String sessionId;

  @override
  ConsumerState<DiaryEntryScreen> createState() => _DiaryEntryScreenState();
}

class _DiaryEntryScreenState extends ConsumerState<DiaryEntryScreen> {
  CookingSession? _session;
  final _minutes = TextEditingController();
  final _temperatures = TextEditingController();
  final _wentWell = TextEditingController();
  final _toImprove = TextEditingController();
  final _notes = TextEditingController();
  double? _rating;
  var _photos = <RecipePhoto>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await ref.read(docsRepositoryProvider.future);
    final session = await docs.session(widget.sessionId);
    if (!mounted) return;
    setState(() {
      _session = session;
      _loading = false;
      if (session != null) {
        final elapsedMinutes = (session.elapsedSeconds(docs.now()) / 60)
            .round();
        _minutes.text =
            '${session.actualMinutes ?? (elapsedMinutes > 0 ? elapsedMinutes : '')}';
        _temperatures.text = session.actualTemperatures.join(', ');
        _wentWell.text = session.wentWell;
        _toImprove.text = session.toImprove;
        _notes.text = session.notes;
        _rating = session.rating;
        _photos = [...session.photos];
      }
    });
  }

  @override
  void dispose() {
    for (final c in [_minutes, _temperatures, _wentWell, _toImprove, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final session = _session;
    if (session == null) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    final now = docs.now();
    final saved = await docs.saveSession(
      session.copyWith(
        status: SessionStatus.finished,
        activeSeconds: session.elapsedSeconds(now),
        resumedAt: null,
        timers: const [],
        actualMinutes: int.tryParse(_minutes.text.trim()),
        actualTemperatures: [
          for (final t in _temperatures.text.split(','))
            if (t.trim().isNotEmpty) t.trim(),
        ],
        photos: [..._photos],
        rating: _rating,
        wentWell: _wentWell.text.trim(),
        toImprove: _toImprove.text.trim(),
        notes: _notes.text.trim(),
      ),
    );
    if (saved.recipeId != null) {
      final repository = await ref.read(recipeRepositoryProvider.future);
      final recipe = await repository.getById(saved.recipeId!);
      if (recipe != null &&
          (recipe.lastCookedAt == null ||
              recipe.lastCookedAt!.isBefore(saved.cookedAt))) {
        await repository.markCooked(recipe.id, saved.cookedAt);
      }
    }
    if (!mounted) return;
    showMessage(context, 'Uloženo do kuchařského deníku.');
    context.pop();
  }

  Future<void> _delete() async {
    final ok = await confirm(
      context,
      title: 'Smazat záznam?',
      message: 'Záznam vaření zmizí z deníku na všech zařízeních.',
      confirmLabel: 'Smazat',
      destructive: true,
    );
    if (!ok) return;
    final docs = await ref.read(docsRepositoryProvider.future);
    await docs.deleteSession(widget.sessionId);
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zápis do deníku'),
        actions: [
          if (session != null && session.isFinished)
            IconButton(
              tooltip: 'Smazat záznam',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _delete,
            ),
        ],
      ),
      bottomNavigationBar: session == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CopperButton(
                      label: 'Uložit do deníku',
                      icon: Icons.check_rounded,
                      onPressed: _save,
                    ),
                  ],
                ),
              ),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : session == null
          ? const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Záznam nenalezen',
              message: 'Tento záznam v deníku není.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  session.recipeTitle,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(
                  [
                    diaryDate(session.cookedAt),
                    if (session.versionNumber != null)
                      'verze ${session.versionNumber}',
                    if (session.servings != null)
                      '${formatQuantity(session.servings!)} porcí/ks',
                  ].join(' · '),
                  style: const TextStyle(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                const Text('Hodnocení'),
                const SizedBox(height: 4),
                StarRating(
                  value: _rating,
                  size: 34,
                  onChanged: (value) => setState(() => _rating = value),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _minutes,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Skutečný čas (min)',
                          helperText: 'Předvyplněno podle stopek',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _temperatures,
                        decoration: const InputDecoration(
                          labelText: 'Skutečné teploty',
                          helperText: 'např. 160 °C, jádro 62 °C',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _wentWell,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Co se povedlo'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _toImprove,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Co příště zlepšit',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _notes,
                  maxLines: null,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Poznámky'),
                ),
                const SizedBox(height: 16),
                const SectionTitle('Fotky'),
                PhotoListEditor(
                  recipeId: 'session-${session.id}',
                  photos: [..._photos],
                  onChanged: (photos) => setState(() => _photos = photos),
                ),
              ],
            ),
    );
  }
}
