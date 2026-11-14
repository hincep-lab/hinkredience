import 'dart:io';

import 'package:path/path.dart' as p;

import 'recipe.dart';

/// Ukládání fotografií receptů do složky aplikace.
///
/// V databázi je jen relativní cesta – absolutní cesta ke složce aplikace se
/// na iOS mění při každé aktualizaci.
class PhotoStore {
  PhotoStore(this.baseDirectory);

  final Directory baseDirectory;

  /// Zkopíruje vybraný obrázek do složky aplikace a vrátí záznam fotografie.
  Future<RecipePhoto> import({
    required String recipeId,
    required String photoId,
    required String sourcePath,
  }) async {
    final relative = p.join('photos', recipeId, '$photoId.jpg');
    final target = File(p.join(baseDirectory.path, relative));
    await target.parent.create(recursive: true);
    await File(sourcePath).copy(target.path);
    return RecipePhoto(id: photoId, localPath: relative);
  }

  /// Soubor fotografie v telefonu, pokud existuje.
  File? localFile(RecipePhoto photo) {
    final relative = photo.localPath;
    if (relative == null || relative.isEmpty) return null;
    final file = File(p.join(baseDirectory.path, relative));
    return file.existsSync() ? file : null;
  }
}
