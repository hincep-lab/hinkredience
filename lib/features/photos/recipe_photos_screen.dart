import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/app_colors.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';
import '../../data/recipe.dart';
import 'photo_editor.dart';

/// Správa fotek receptu bez otevírání celého editoru. Každá změna se hned
/// uloží (bez nové verze receptu) a sama se synchronizuje.
class RecipePhotosScreen extends ConsumerWidget {
  const RecipePhotosScreen({super.key, required this.recipeId});

  final String recipeId;

  Future<void> _save(WidgetRef ref, List<RecipePhoto> photos) async {
    final repository = await ref.read(recipeRepositoryProvider.future);
    await repository.setPhotos(recipeId, photos);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipe = ref.watch(recipeProvider(recipeId)).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Fotografie')),
      body: recipe == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  recipe.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                PhotoListEditor(
                  recipeId: recipe.id,
                  photos: recipe.photos,
                  height: 150,
                  onChanged: (photos) => _save(ref, photos),
                ),
                const SizedBox(height: 16),
                const Text(
                  'První fotka je hlavní – zobrazuje se v seznamu receptů a '
                  'nahoře v detailu. Pořadí změníte podržením a přetažením '
                  'fotky, nebo přes tlačítko ⋯ u fotky. Fotky se samy '
                  'synchronizují a uvidí je i ChatGPT.',
                  style: TextStyle(color: AppColors.textSecondary, height: 1.4),
                ),
                if (recipe.photos.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  for (var i = 0; i < recipe.photos.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GestureDetector(
                        onTap: () => openPhotoViewer(
                          context,
                          recipe.photos,
                          initialIndex: i,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: AspectRatio(
                            aspectRatio: 4 / 3,
                            child: RecipePhotoView(photo: recipe.photos[i]),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
