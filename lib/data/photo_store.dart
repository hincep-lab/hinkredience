import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'recipe.dart';

/// Délka delší strany náhledu v pixelech.
const thumbnailSize = 480;

/// Zmenší fotografii na náhled (JPEG). Běží v samostatném vlákně, aby se
/// aplikace při zpracování velké fotky nezasekla. Vrací `null`, když obrázek
/// nejde přečíst.
Future<Uint8List?> makeThumbnail(Uint8List bytes, {int size = thumbnailSize}) =>
    Isolate.run(() => _thumbnail(bytes, size));

Uint8List? _thumbnail(Uint8List bytes, int size) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final oriented = img.bakeOrientation(decoded);
    final landscape = oriented.width >= oriented.height;
    final longer = landscape ? oriented.width : oriented.height;
    final resized = longer <= size
        ? oriented
        : img.copyResize(
            oriented,
            width: landscape ? size : null,
            height: landscape ? null : size,
            interpolation: img.Interpolation.average,
          );
    return img.encodeJpg(resized, quality: 78);
  } catch (_) {
    return null;
  }
}

/// Relativní cesta náhledu k relativní cestě fotky: `a/b.jpg` → `a/b_t.jpg`.
String thumbnailPathFor(String path) {
  final extension = p.extension(path);
  final base = extension.isEmpty
      ? path
      : path.substring(0, path.length - extension.length);
  return '${base}_t.jpg';
}

/// Ukládání fotografií receptů do složky aplikace.
///
/// V databázi je jen relativní cesta – absolutní cesta ke složce aplikace se
/// na iOS mění při každé aktualizaci. Ke každé fotce se ukládá i malý náhled
/// pro seznamy (soubor s příponou `_t.jpg`).
class PhotoStore {
  PhotoStore(this.baseDirectory);

  final Directory baseDirectory;

  File _file(String relative) => File(p.join(baseDirectory.path, relative));

  bool _safe(String relative) =>
      relative.isNotEmpty &&
      !relative.contains('..') &&
      !p.isAbsolute(relative);

  /// Zkopíruje vybraný obrázek do složky aplikace a vrátí záznam fotografie.
  /// Fotka je už zmenšená a zkomprimovaná při výběru (image_picker).
  Future<RecipePhoto> import({
    required String recipeId,
    required String photoId,
    required String sourcePath,
  }) async {
    final relative = p.join('photos', recipeId, '$photoId.jpg');
    final target = _file(relative);
    await target.parent.create(recursive: true);
    await File(sourcePath).copy(target.path);
    await ensureThumbnail(relative);
    return RecipePhoto(id: photoId, localPath: relative);
  }

  /// Uloží fotku staženou ze serveru (mezipaměť pro režim bez internetu)
  /// a vrátí její relativní cestu.
  Future<String> saveDownloaded({
    required String recipeId,
    required String photoId,
    required Uint8List bytes,
  }) async {
    final relative = p.join('photos', recipeId, '$photoId.jpg');
    final target = _file(relative);
    await target.parent.create(recursive: true);
    // Nejdřív do dočasného souboru, aby nikdy nezůstala polovičatá fotka.
    final temp = File('${target.path}.part');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
    await ensureThumbnail(relative);
    return relative;
  }

  /// Vytvoří náhled, pokud ještě neexistuje. Vrací soubor náhledu, nebo
  /// `null`, když fotka chybí nebo nejde přečíst.
  Future<File?> ensureThumbnail(String relative) async {
    if (!_safe(relative)) return null;
    final thumb = _file(thumbnailPathFor(relative));
    if (await thumb.exists()) return thumb;
    final source = _file(relative);
    if (!await source.exists()) return null;
    final bytes = await makeThumbnail(await source.readAsBytes());
    if (bytes == null) return null;
    await thumb.writeAsBytes(bytes, flush: true);
    return thumb;
  }

  /// Smaže z telefonu soubory fotografií (relativní cesty z databáze) i jejich
  /// náhledy. Chybějící soubor není chyba.
  Future<void> deleteFiles(Iterable<String> relativePaths) async {
    for (final relative in relativePaths) {
      if (!_safe(relative)) continue;
      for (final file in [_file(relative), _file(thumbnailPathFor(relative))]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          // Soubor nejde smazat (např. je právě otevřený) – nevadí.
        }
      }
    }
  }

  /// Soubor fotografie v telefonu, pokud existuje.
  File? localFile(RecipePhoto photo) {
    final relative = photo.localPath;
    if (relative == null || !_safe(relative)) return null;
    final file = _file(relative);
    return file.existsSync() ? file : null;
  }

  /// Náhled fotografie v telefonu, pokud existuje.
  File? thumbnailFile(RecipePhoto photo) {
    final relative = photo.localPath;
    if (relative == null || !_safe(relative)) return null;
    final file = _file(thumbnailPathFor(relative));
    return file.existsSync() ? file : null;
  }
}
