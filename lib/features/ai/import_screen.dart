import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/ai_service.dart';
import 'ai_common.dart';
import 'draft_review_screen.dart';

enum _Source { text, link, photo }

/// Import receptu z textu, webového odkazu nebo fotografie. AI podklad
/// převede na strukturovaný recept, který uživatel před uložením zkontroluje.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final _text = TextEditingController();
  final _link = TextEditingController();
  _Source _source = _Source.text;
  String? _photoBase64;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _addPhoto() async {
    final photo = await choosePhotoForAi(context);
    if (photo == null || !mounted) return;
    setState(() => _photoBase64 = photo);
  }

  Future<void> _import() async {
    final service = ref.read(aiServiceProvider);
    if (service == null || _busy) return;

    String? text;
    String? url;
    String? photo;
    switch (_source) {
      case _Source.text:
        text = _text.text.trim();
        if (text.length < 20) {
          showMessage(context, 'Vložte celý text receptu.');
          return;
        }
      case _Source.link:
        url = normalizeWebUrl(_link.text);
        if (url == null) {
          showMessage(context, 'Zadejte platný odkaz na stránku s receptem.');
          return;
        }
      case _Source.photo:
        photo = _photoBase64;
        if (photo == null) {
          showMessage(context, 'Nejdřív přidejte fotografii receptu.');
          return;
        }
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final proposal = await service.importRecipe(
        text: text,
        url: url,
        imageBase64: photo,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      context.push(
        Routes.draft,
        extra: DraftReviewArgs(
          proposal: proposal,
          heading: 'Importovaný recept',
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(aiServiceProvider);
    final error = _error;

    return Scaffold(
      appBar: AppBar(title: const Text('Import receptu')),
      body: service == null
          ? const AiUnavailable()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                SegmentedButton<_Source>(
                  segments: const [
                    ButtonSegment(
                      value: _Source.text,
                      label: Text('Text'),
                      icon: Icon(Icons.notes_rounded),
                    ),
                    ButtonSegment(
                      value: _Source.link,
                      label: Text('Odkaz'),
                      icon: Icon(Icons.link_rounded),
                    ),
                    ButtonSegment(
                      value: _Source.photo,
                      label: Text('Fotka'),
                      icon: Icon(Icons.photo_camera_outlined),
                    ),
                  ],
                  selected: {_source},
                  onSelectionChanged: (selection) =>
                      setState(() => _source = selection.first),
                ),
                const SizedBox(height: 16),
                switch (_source) {
                  _Source.text => TextField(
                    controller: _text,
                    minLines: 8,
                    maxLines: 16,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Text receptu nebo ručně psané poznámky',
                      hintText: 'Vložte sem recept tak, jak ho máte – suroviny i postup.',
                      alignLabelWithHint: true,
                    ),
                  ),
                  _Source.link => TextField(
                    controller: _link,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Odkaz na stránku s receptem',
                      hintText: 'https://…',
                      prefixIcon: Icon(Icons.link_rounded),
                    ),
                  ),
                  _Source.photo => HkCard(
                    onTap: _busy ? null : _addPhoto,
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      children: [
                        Icon(
                          _photoBase64 == null
                              ? Icons.add_a_photo_outlined
                              : Icons.check_circle_outline_rounded,
                          color: AppColors.copperGold,
                          size: 32,
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            _photoBase64 == null
                                ? 'Vyfoťte nebo vyberte fotografii receptu '
                                      '(stránka z kuchařky, ručně psaný lístek).'
                                : 'Fotografie je připravená. Klepnutím vyberete jinou.',
                            style: const TextStyle(height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                },
                const SizedBox(height: 10),
                const Text(
                  'Recept se převezme vlastními slovy a u odkazu se uloží adresa '
                  'zdroje. Import z PDF zatím není hotový.',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
                const SizedBox(height: 16),
                CopperButton(
                  label: 'Převést na recept',
                  icon: Icons.auto_awesome_rounded,
                  busy: _busy,
                  onPressed: _import,
                ),
                if (_busy)
                  const AiProgress(label: 'Čtu podklad a skládám recept…'),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  AiErrorCard(error: error),
                ],
              ],
            ),
    );
  }
}
