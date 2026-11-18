// Zkouška čtení receptu z fotky přímo v Androidu (release sestavení, stejné
// nastavení R8 jako aplikace). Spouští ji CI na emulátoru:
//   flutter build apk --release -t integration_test/ocr_probe.dart
// Výsledek se vypíše do logcatu s předponou HINK_OCR.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hinkredience/core/ocr.dart';
import 'package:hinkredience/core/recipe_text.dart';
import 'package:path_provider/path_provider.dart';

import 'recipe_photo.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('OCR')))));
  await Future<void>.delayed(const Duration(seconds: 2));
  // ignore: avoid_print
  void log(String s) => print('HINK_OCR $s');
  try {
    // Stejně jako image_picker: fotka v dočasné složce aplikace.
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/scaled_recept.jpg');
    await file.writeAsBytes(base64Decode(recipePhotoBase64));
    log('FILE ${file.path} ${await file.length()}');

    final text = await readTextFromImage(file.path);
    log('TEXT_BEGIN');
    for (final line in const LineSplitter().convert(text)) {
      log('| $line');
    }
    log('TEXT_END');
    final recipe = parseRecipeText(text);
    if (recipe == null) {
      log('FAIL nepodařilo se rozdělit na recept');
    } else {
      log('TITLE ${recipe.title}');
      log('INGREDIENTS ${recipe.ingredients.length}');
      for (final i in recipe.ingredients) {
        log('  - ${i.quantity ?? ''} ${i.unit} ${i.name}');
      }
      log('STEPS ${recipe.steps.length}');
      log(
        recipe.ingredients.length >= 6 && recipe.steps.length >= 4
            ? 'PASS'
            : 'FAIL málo surovin nebo kroků',
      );
    }
  } catch (error, stack) {
    log('ERROR ${error.runtimeType}: $error');
    log('STACK $stack');
    log('FAIL výjimka');
  }

  // Neplatný soubor musí skončit srozumitelnou chybou, ne pádem.
  try {
    final dir = await getTemporaryDirectory();
    final bad = File('${dir.path}/neni_obrazek.jpg');
    await bad.writeAsString('tohle není obrázek');
    await readTextFromImage(bad.path);
    log('BADFILE no-error');
  } catch (error) {
    log('BADFILE ${error.runtimeType}: $error');
  }
  try {
    await readTextFromImage('/neexistuje/foto.jpg');
    log('MISSING no-error');
  } catch (error) {
    log('MISSING ${error.runtimeType}: $error');
  }
  log('DONE');
}
