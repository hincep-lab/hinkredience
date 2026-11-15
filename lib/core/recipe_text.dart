import '../data/ai_models.dart';
import 'kitchen_math.dart';
import 'shopping.dart';

/// Recept z volného textu bez AI: vložený text, popis videa nebo text
/// přečtený z fotky. Rozpozná nadpisy „Suroviny“ / „Postup“, řádky
/// s množstvím, číslované kroky a počet porcí. Výsledek je jen návrh –
/// uživatel ho před uložením zkontroluje.
RecipeDraft? parseRecipeText(String input) {
  final lines = [
    for (final raw in input.split(RegExp(r'\r?\n')))
      if (_clean(raw).isNotEmpty) _clean(raw),
  ];
  if (lines.isEmpty) return null;

  String? title;
  var servings = 4.0;
  final ingredients = <DraftIngredient>[];
  final steps = <DraftStep>[];
  final notes = <String>[];
  var section = _Section.unknown;

  for (final line in lines) {
    final folded = foldText(line).replaceAll(RegExp(r'[:\s.]+$'), '');
    if (_ingredientHeading.hasMatch(folded)) {
      section = _Section.ingredients;
      _readServings(line, (value) => servings = value);
      continue;
    }
    if (_stepHeading.hasMatch(folded)) {
      section = _Section.steps;
      continue;
    }
    if (_readServings(line, (value) => servings = value) && line.length < 40) {
      continue;
    }
    if (RegExp(r'^(https?://|www\.|#|@)').hasMatch(line)) continue;

    final numberedStep = RegExp(r'^\d{1,2}\s*[.)]\s+\S').hasMatch(line);
    final bullet = RegExp(r'^[-–•*·▪●○]\s*').hasMatch(line);
    final startsWithAmount = RegExp(r'^[-–•*·]?\s*[\d½¼¾⅓⅔]').hasMatch(line);

    if (title == null &&
        section == _Section.unknown &&
        !startsWithAmount &&
        !numberedStep &&
        line.length <= 80) {
      title = line;
      continue;
    }

    final asIngredient =
        section == _Section.ingredients ||
        (section == _Section.unknown &&
            (bullet || startsWithAmount) &&
            line.length <= 70 &&
            !numberedStep);
    if (asIngredient && line.length <= 120) {
      final ingredient = parseIngredientLine(line);
      if (ingredient != null) ingredients.add(ingredient);
      continue;
    }

    if (section == _Section.steps ||
        numberedStep ||
        line.length > 60 ||
        steps.isNotEmpty ||
        (ingredients.isNotEmpty && line.endsWith('.'))) {
      final instruction = line.replaceFirst(
        RegExp(r'^(\d{1,2}\s*[.)]|[-–•*·])\s*'),
        '',
      );
      steps.add(
        DraftStep(
          instruction: instruction,
          durationMinutes: _minutesIn(instruction),
          temperatureC: _temperatureIn(instruction),
        ),
      );
      continue;
    }
    notes.add(line);
  }

  if (ingredients.isEmpty && steps.isEmpty) return null;
  return RecipeDraft(
    title: title ?? 'Nový recept',
    servings: servings,
    notes: notes.join('\n'),
    ingredients: ingredients,
    steps: steps,
  );
}

/// „500 g hladké mouky (prosáté)“ → surovina s množstvím a poznámkou.
DraftIngredient? parseIngredientLine(String line) {
  var text = line.replaceFirst(RegExp(r'^[-–•*·▪●○]\s*'), '').trim();
  var note = '';
  final paren = RegExp(r'\(([^)]*)\)').firstMatch(text);
  if (paren != null) {
    note = paren.group(1)!.trim();
    text = text.replaceFirst(paren.group(0)!, ' ').trim();
  }
  for (final entry in _fractions.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }
  text = text.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r',$'), '');
  if (text.isEmpty) return null;
  final draft = parseShoppingText(text);
  if (draft.name.isEmpty) return null;
  return DraftIngredient(
    name: draft.name,
    quantity: draft.quantity,
    unit: draft.quantity == null ? '' : draft.unit,
    note: note,
  );
}

enum _Section { unknown, ingredients, steps }

final _ingredientHeading = RegExp(
  r'^(suroviny|ingredience|potrebujeme|potrebujete|budete potrebovat|na \S+.*potrebujeme|suroviny na .*|suroviny pro .*)$',
);
final _stepHeading = RegExp(
  r'^(postup|priprava|navod|jak na to|postup pripravy)$',
);

const _fractions = {
  '½': '0,5',
  '¼': '0,25',
  '¾': '0,75',
  '⅓': '0,33',
  '⅔': '0,67',
  '1/2': '0,5',
  '1/4': '0,25',
  '3/4': '0,75',
};

String _clean(String line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim();

/// „Na 4 porce“, „Porce: 6“, „12 kusů“ – nastaví počet porcí.
bool _readServings(String line, void Function(double) set) {
  final folded = foldText(line);
  final match =
      RegExp(r'(\d+)\s*(porc|osob|kus|ks)').firstMatch(folded) ??
      RegExp(r'(?:porce|porci|pocet porci)\s*[:\-]?\s*(\d+)')
          .firstMatch(folded);
  if (match == null) return false;
  final value = double.tryParse(match.group(1)!);
  if (value == null || value <= 0 || value > 100) return false;
  set(value);
  return true;
}

int? _minutesIn(String text) {
  final folded = foldText(text);
  final hours = RegExp(r'(\d+(?:[.,]\d+)?)\s*(hod|h\b)').firstMatch(folded);
  final minutes = RegExp(r'(\d+)\s*(min)').firstMatch(folded);
  var total = 0.0;
  if (hours != null) {
    total += double.parse(hours.group(1)!.replaceAll(',', '.')) * 60;
  }
  if (minutes != null) total += double.parse(minutes.group(1)!);
  return total > 0 ? total.round() : null;
}

double? _temperatureIn(String text) {
  final match = RegExp(r'(\d{2,3})\s*°\s*C?').firstMatch(text);
  final value = match == null ? null : double.tryParse(match.group(1)!);
  return value != null && value >= 30 && value <= 320 ? value : null;
}
