import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';

/// Nejdelší strana ukládané fotky a kvalita JPEG. Fotku z 50Mpx fotoaparátu
/// tak zmenší z ~15 MB na ~0,5 MB a přitom zůstane ostrá i na tabletu.
const photoMaxSide = 2048.0;
const photoQuality = 85;

/// Zeptá se, odkud fotku vzít (galerie, nebo fotoaparát).
Future<ImageSource?> choosePhotoSource(BuildContext context) =>
    showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Vybrat z galerie'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Vyfotit'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

/// Vybere nebo vyfotí fotku, zmenší ji, uloží do složky aplikace (i s
/// náhledem) a vrátí záznam fotky. `null` = uživatel nic nevybral.
Future<RecipePhoto?> pickRecipePhoto(
  BuildContext context,
  WidgetRef ref, {
  required String recipeId,
  required ImageSource source,
}) async {
  try {
    final picked = await ImagePicker().pickImage(
      source: source,
      maxWidth: photoMaxSide,
      maxHeight: photoMaxSide,
      imageQuality: photoQuality,
    );
    if (picked == null) return null;
    final repository = await ref.read(recipeRepositoryProvider.future);
    return await ref
        .read(photoStoreProvider)
        .import(
          recipeId: recipeId,
          photoId: repository.newId(),
          sourcePath: picked.path,
        );
  } on PlatformException catch (error) {
    if (context.mounted) {
      showMessage(
        context,
        error.code.contains('denied') || error.code.contains('access')
            ? 'Aplikace nemá povolený přístup k fotkám nebo fotoaparátu. '
                  'Povolte ho v nastavení telefonu.'
            : 'Fotku se nepodařilo přidat.',
      );
    }
  } catch (_) {
    if (context.mounted) showMessage(context, 'Fotku se nepodařilo přidat.');
  }
  return null;
}

/// Otevře fotky přes celou obrazovku (posouvání, přiblížení prsty).
Future<void> openPhotoViewer(
  BuildContext context,
  List<RecipePhoto> photos, {
  int initialIndex = 0,
}) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) =>
        PhotoViewerScreen(photos: photos, initialIndex: initialIndex),
  ),
);

/// Úprava fotek receptu: přidání, pořadí (podržením a přetažením), hlavní
/// fotka (vždy ta první), nahrazení a odebrání.
class PhotoListEditor extends ConsumerWidget {
  const PhotoListEditor({
    super.key,
    required this.recipeId,
    required this.photos,
    required this.onChanged,
    this.height = 124,
  });

  final String recipeId;
  final List<RecipePhoto> photos;
  final ValueChanged<List<RecipePhoto>> onChanged;
  final double height;

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final source = await choosePhotoSource(context);
    if (source == null || !context.mounted) return;
    final photo = await pickRecipePhoto(
      context,
      ref,
      recipeId: recipeId,
      source: source,
    );
    if (photo != null) onChanged([...photos, photo]);
  }

  Future<void> _replace(BuildContext context, WidgetRef ref, int index) async {
    final source = await choosePhotoSource(context);
    if (source == null || !context.mounted) return;
    final photo = await pickRecipePhoto(
      context,
      ref,
      recipeId: recipeId,
      source: source,
    );
    if (photo == null) return;
    onChanged([
      for (var i = 0; i < photos.length; i++) i == index ? photo : photos[i],
    ]);
  }

  Future<void> _options(BuildContext context, WidgetRef ref, int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.fullscreen_rounded),
              title: const Text('Zobrazit'),
              onTap: () => Navigator.of(sheetContext).pop('view'),
            ),
            if (index > 0)
              ListTile(
                leading: const Icon(Icons.star_outline_rounded),
                title: const Text('Nastavit jako hlavní'),
                onTap: () => Navigator.of(sheetContext).pop('cover'),
              ),
            if (index > 0)
              ListTile(
                leading: const Icon(Icons.arrow_back_rounded),
                title: const Text('Posunout dopředu'),
                onTap: () => Navigator.of(sheetContext).pop('left'),
              ),
            if (index < photos.length - 1)
              ListTile(
                leading: const Icon(Icons.arrow_forward_rounded),
                title: const Text('Posunout dozadu'),
                onTap: () => Navigator.of(sheetContext).pop('right'),
              ),
            ListTile(
              leading: const Icon(Icons.swap_horiz_rounded),
              title: const Text('Nahradit jinou fotkou'),
              onTap: () => Navigator.of(sheetContext).pop('replace'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: AppColors.danger,
              ),
              title: const Text('Odebrat z receptu'),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;
    final list = [...photos];
    switch (action) {
      case 'view':
        await openPhotoViewer(context, photos, initialIndex: index);
      case 'cover':
        list.insert(0, list.removeAt(index));
        onChanged(list);
      case 'left':
        list.insert(index - 1, list.removeAt(index));
        onChanged(list);
      case 'right':
        list.insert(index + 1, list.removeAt(index));
        onChanged(list);
      case 'replace':
        await _replace(context, ref, index);
      case 'remove':
        list.removeAt(index);
        onChanged(list);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: height,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        onReorder: (from, to) {
          final list = [...photos];
          final item = list.removeAt(from);
          list.insert(to > from ? to - 1 : to, item);
          onChanged(list);
        },
        footer: SizedBox(
          width: height,
          child: HkCard(
            onTap: () => _add(context, ref),
            padding: const EdgeInsets.all(8),
            radius: 16,
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.add_a_photo_outlined,
                    color: AppColors.copperGold,
                    size: 30,
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Přidat fotku',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ),
        itemBuilder: (context, index) {
          final photo = photos[index];
          return Padding(
            key: ValueKey(photo.id),
            padding: const EdgeInsets.only(right: 10),
            child: GestureDetector(
              onTap: () => _options(context, ref, index),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: height,
                      height: height,
                      child: RecipePhotoView(photo: photo, thumbnail: true),
                    ),
                  ),
                  if (index == 0)
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.background.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 3,
                          ),
                          child: Text(
                            'Hlavní',
                            style: TextStyle(
                              color: AppColors.copperGold,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: IconButton.filled(
                      tooltip: 'Možnosti fotky',
                      style: IconButton.styleFrom(
                        backgroundColor: AppColors.background.withValues(
                          alpha: 0.7,
                        ),
                        foregroundColor: AppColors.text,
                        minimumSize: const Size(32, 32),
                        padding: EdgeInsets.zero,
                      ),
                      icon: const Icon(Icons.more_horiz_rounded, size: 18),
                      onPressed: () => _options(context, ref, index),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Prohlížení fotek přes celou obrazovku.
class PhotoViewerScreen extends StatefulWidget {
  const PhotoViewerScreen({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });

  final List<RecipePhoto> photos;
  final int initialIndex;

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.photos.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(count > 1 ? 'Fotka ${_index + 1} z $count' : 'Fotka'),
        leading: IconButton(
          tooltip: 'Zavřít',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: count,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) => InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Center(
            child: RecipePhotoView(
              photo: widget.photos[index],
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    );
  }
}
