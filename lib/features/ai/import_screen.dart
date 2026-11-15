import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/ocr.dart';
import '../../core/recipe_text.dart';
import '../../core/widgets.dart';
import '../../data/ai_models.dart';
import '../../data/ai_service.dart' show normalizeWebUrl;
import '../../data/link_import.dart';
import 'ai_common.dart';
import 'draft_review_screen.dart';

enum _Source { text, link, photo }

/// Načte recept z odkazu na server HINKredience (bez AI). `null` = bez účtu.
final linkImporterProvider = Provider<LinkImporter?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null || !ref.watch(sessionProvider).isSignedIn) return null;
  return LinkImporter(client);
});

/// Import receptu z textu, webového odkazu (i popisu videa) nebo fotky.
/// Ve výchozím stavu úplně bez AI: text se rozdělí podle pravidel, stránka
/// se přečte ze strukturovaných dat a fotka přes čtení textu v telefonu.
/// Placenou AI lze použít jen výslovně, když je v nastavení zapnutá.
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final _text = TextEditingController();
  final _link = TextEditingController();
  _Source _source = _Source.text;
  XFile? _photo;
  bool _useAi = false;
  bool _busy = false;
  Object? _error;

  @override
  void dispose() {
    _text.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Vyfotit'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Vybrat z galerie'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2400,
        maxHeight: 2400,
        imageQuality: 90,
      );
      if (picked != null && mounted) {
        setState(() {
          _photo = picked;
          _error = null;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        showMessage(context, _pickerErrorMessage(error, source));
      }
    } catch (_) {
      if (mounted) {
        showMessage(
          context,
          'Fotografii se nepodařilo načíst. Zkuste to prosím znovu.',
        );
      }
    }
  }

  /// Srozumitelná zpráva místo technické chyby výběru fotky.
  String _pickerErrorMessage(PlatformException error, ImageSource source) {
    final code = error.code.toLowerCase();
    if (code.contains('camera_access_denied')) {
      return 'Aplikace nemá povolený fotoaparát. Povolte ho v Nastavení '
          'telefonu → Aplikace → HINKredience° → Oprávnění.';
    }
    if (code.contains('photo_access_denied') ||
        code.contains('access_denied')) {
      return 'Aplikace nemá přístup k fotkám. Povolte ho v Nastavení '
          'telefonu → Aplikace → HINKredience° → Oprávnění.';
    }
    if (code.contains('no_available_camera')) {
      return 'Fotoaparát není k dispozici. Vyberte fotku z galerie.';
    }
    return source == ImageSource.camera
        ? 'Vyfotit se nepodařilo. Zkuste to znovu nebo vyberte fotku z galerie.'
        : 'Fotografii se nepodařilo načíst. Zkuste to znovu nebo vyberte '
              'jinou.';
  }

  /// Chyba importu pro uživatele (bez technických výpisů).
  String _friendlyError(Object error) {
    if (error is OcrException) return error.message;
    if (error is PlatformException) {
      return 'Text z fotky se nepodařilo přečíst. Zkuste to znovu, případně '
          'vyberte jinou nebo ostřejší fotku.';
    }
    final text = error.toString().replaceFirst('Exception: ', '');
    // Technické výpisy (třídy Javy, zásobníky) uživateli neukazujeme.
    if (RegExp(r'java\.|\.kt|Exception|Error:|null object').hasMatch(text)) {
      return 'Něco se nepovedlo. Zkuste to prosím znovu.';
    }
    return text;
  }

  void _review(DraftProposal proposal) {
    context.push(
      Routes.draft,
      extra: DraftReviewArgs(proposal: proposal, heading: 'Importovaný recept'),
    );
  }

  /// Text (vložený nebo přečtený z fotky) → návrh receptu podle pravidel.
  DraftProposal? _fromText(String text, {String summary = ''}) {
    final recipe = parseRecipeText(text);
    if (recipe == null) return null;
    return DraftProposal(recipe: recipe, summary: summary);
  }

  Future<void> _import() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    if (_useAi) return _importWithAi();

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      DraftProposal? proposal;
      switch (_source) {
        case _Source.text:
          final text = _text.text.trim();
          if (text.length < 15) throw Exception('Vložte celý text receptu.');
          proposal = _fromText(
            text,
            summary: 'Rozděleno na suroviny a postup bez AI – zkontrolujte.',
          );
          if (proposal == null) {
            throw Exception(
              'V textu jsem nenašel suroviny ani postup. Zkuste nad suroviny '
              'napsat „Suroviny:“ a nad postup „Postup:“.',
            );
          }
        case _Source.link:
          final url = normalizeWebUrl(_link.text);
          if (url == null) {
            throw Exception('Zadejte platný odkaz na stránku nebo video.');
          }
          final importer = ref.read(linkImporterProvider);
          if (importer == null) {
            throw Exception(
              'Načtení z odkazu potřebuje přihlášení (stránku čte server).',
            );
          }
          proposal = await importer.fromUrl(url);
        case _Source.photo:
          final photo = _photo;
          if (photo == null) throw Exception('Nejdřív přidejte fotografii.');
          if (!ocrAvailable) {
            throw const OcrException(
              'Čtení textu z fotky se nenačetlo. Zavřete aplikaci, otevřete '
              'ji znovu a zkuste to ještě jednou.',
            );
          }
          final text = await readTextFromImage(photo.path);
          if (text.trim().isEmpty) {
            throw Exception(
              'Na fotce jsem nenašel žádný text. Zkuste ostřejší fotku.',
            );
          }
          proposal = _fromText(
            text,
            summary: 'Přečteno z fotky bez AI – zkontrolujte, prosím.',
          );
          if (proposal == null) {
            // Text se přečetl, ale nejde rozdělit – nabídneme ho k úpravě.
            _text.text = text;
            setState(() => _source = _Source.text);
            throw Exception(
              'Text z fotky jsem přečetl, ale nepoznal suroviny a postup. '
              'Upravte ho níže a dejte „Převést na recept“.',
            );
          }
      }
      if (!mounted) return;
      setState(() => _busy = false);
      _review(proposal);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _importWithAi() async {
    final service = ref.read(aiServiceProvider);
    if (service == null) return;
    String? text;
    String? url;
    String? photo;
    switch (_source) {
      case _Source.text:
        text = _text.text.trim();
      case _Source.link:
        url = normalizeWebUrl(_link.text);
      case _Source.photo:
        final picked = _photo;
        if (picked != null) {
          photo = await pickedToBase64(picked);
        }
    }
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
      _review(proposal);
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
    final aiAvailable = ref.watch(aiServiceProvider) != null;
    final error = _error;
    final photoHint = kIsWeb
        ? 'Vyfoťte nebo vyberte fotku receptu. Text se přečte přímo '
              'v prohlížeči, bez AI. Poprvé se stáhne čtečka textu (asi 9 MB).'
        : 'Vyfoťte stránku z kuchařky nebo lísteček. Text se přečte přímo '
              'v telefonu, bez internetu a bez AI.';

    return Scaffold(
      appBar: AppBar(title: const Text('Import receptu')),
      body: ListView(
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
            onSelectionChanged: (selection) => setState(() {
              _source = selection.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 16),
          switch (_source) {
            _Source.text => TextField(
              controller: _text,
              minLines: 8,
              maxLines: 16,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Text receptu',
                hintText:
                    'Název\nSuroviny:\n500 g mouky\n2 vejce\nPostup:\n'
                    '1. Smíchejte…',
                alignLabelWithHint: true,
              ),
            ),
            _Source.link => TextField(
              controller: _link,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Odkaz na recept nebo video',
                hintText: 'https://…',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            _Source.photo => HkCard(
              onTap: _busy ? null : _pickPhoto,
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(
                    _photo == null
                        ? Icons.add_a_photo_outlined
                        : Icons.check_circle_outline_rounded,
                    color: AppColors.copperGold,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      _photo == null
                          ? photoHint
                          : 'Fotografie je připravená. Klepnutím vyberete '
                                'jinou.',
                      style: const TextStyle(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          },
          const SizedBox(height: 10),
          Text(
            switch (_source) {
              _Source.text =>
                'Rozpozná nadpisy „Suroviny“ a „Postup“, množství, porce, '
                    'časy a teploty. Před uložením vše zkontrolujete.',
              _Source.link =>
                'Funguje s většinou receptových webů (strukturovaná data) '
                    'a s popisem videa na YouTube. Recept z obrazu a zvuku '
                    'videa umí sepsat váš ChatGPT – pošlete mu video a napište '
                    '„ulož to do HINKredience“.',
              _Source.photo =>
                'Nejlépe funguje tištěný text na rovné, dobře osvětlené '
                    'fotce.',
            },
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12.5,
              height: 1.4,
            ),
          ),
          if (aiAvailable) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Použít placenou AI'),
              subtitle: const Text('Jen když import bez AI nestačí.'),
              value: _useAi,
              onChanged: (value) => setState(() => _useAi = value),
            ),
          ],
          const SizedBox(height: 16),
          CopperButton(
            label: 'Převést na recept',
            icon: Icons.receipt_long_rounded,
            busy: _busy,
            onPressed: _import,
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            _useAi
                ? AiErrorCard(error: error)
                : HkCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _friendlyError(error),
                          style: const TextStyle(
                            color: AppColors.danger,
                            height: 1.4,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy ? null : _import,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Zkusit znovu'),
                            ),
                            if (_source == _Source.photo)
                              OutlinedButton.icon(
                                onPressed: _busy ? null : _pickPhoto,
                                icon: const Icon(Icons.add_a_photo_outlined),
                                label: const Text('Vybrat jinou fotku'),
                              ),
                          ],
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
