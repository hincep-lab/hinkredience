/// Kuchyňské vybavení a recept: co z vlastního vybavení recept využije
/// (trouba se sondou a párou, robot na těsto, pizza kámen, hrnce…) a co
/// k němu chybí (vaflovač, sous-vide…).
///
/// Vybavení se čte z toho, co má uživatel uložené (název, druh,
/// schopnosti) – nic se nedomýšlí. Recept se posuzuje podle uložených
/// způsobů přípravy, teplot a textu postupu.
library;

import '../data/recipe.dart';
import 'kitchen_math.dart' show foldText;
import 'recipe_groups.dart';

/// Jeden spotřebič nebo nádobí z vybavení uživatele.
class Appliance {
  const Appliance({required this.name, this.kind = '', this.detail = ''});

  final String name;

  /// Druh („trouba“, „hrnec“, „kuchyňský robot“…).
  final String kind;

  /// Schopnosti a poznámky („Teplotní sonda · Teploty až 300 °C“).
  final String detail;

  String get _text => foldText('$name | $kind | $detail');

  bool get isOven => _text.contains('troub');
  bool get hasSteam => isOven && RegExp(r'steam|\bpar[ay]?\b').hasMatch(_text);
  bool get hasProbe => _text.contains('sond');
  bool get hasPizzaProgram => isOven && _text.contains('pizza program');
  bool get isPizzaStone =>
      !isOven && (_text.contains('pizza') || _text.contains('kamen'));
  bool get isMultiCooker =>
      _text.contains('multifunkc') || _text.contains('elitecook');
  bool get isPressure => _text.contains('tlak');
  bool get isPot =>
      !isMultiCooker &&
      (_text.contains('hrnec') ||
          _text.contains('hrnc') ||
          _text.contains('kastrol'));
  bool get isPan => _text.contains('panev') || _text.contains('panv');
  bool get isMixer =>
      _text.contains('robot') ||
      _text.contains('hnet') ||
      _text.contains('gratussino');
  bool get isWaffle => _text.contains('vafl');
  bool get isSousVide => _text.contains('sous');
  bool get isGrill => _text.contains('gril');

  /// Nejvyšší teplota trouby („až 300 °C“), nebo null.
  int? get maxTemperature {
    final match = RegExp(r'(\d{3})\s*°\s*c').firstMatch(_text);
    return match == null ? null : int.parse(match.group(1)!);
  }

  /// Objem hrnce v litrech („5,5 l“), nebo null.
  double? get litres {
    final match = RegExp(r'(\d+(?:[.,]\d+)?)\s*l\b').firstMatch(_text);
    return match == null
        ? null
        : double.parse(match.group(1)!.replaceAll(',', '.'));
  }
}

/// Rada, jak recept udělat na vlastním vybavení.
class EquipmentTip {
  const EquipmentTip(this.appliance, this.text);

  /// Název spotřebiče, kterého se rada týká.
  final String appliance;
  final String text;
}

/// Jak recept sedí na vybavení uživatele.
class EquipmentFit {
  const EquipmentFit({this.tips = const [], this.missing = const []});

  final List<EquipmentTip> tips;

  /// Co k receptu chybí (popis slovy).
  final List<String> missing;

  bool get isEmpty => tips.isEmpty && missing.isEmpty;

  /// Recept jde udělat s tím, co uživatel má.
  bool get fits => missing.isEmpty;
}

String _recipeText(Recipe r) => foldText(
  [
    r.title,
    r.description,
    r.category,
    ...r.equipment,
    ...r.temperatures,
    r.notes,
    for (final s in r.steps) s.instruction,
    for (final i in r.ingredients) i.name,
  ].join(' | '),
);

/// Nejvyšší teplota pečení, kterou recept uvádí (kroky a teploty), nebo null.
int? _maxOvenTemperature(Recipe r) {
  var best = 0;
  for (final s in r.steps) {
    final t = s.temperatureC;
    // Sous-vide a olej na smažení nejsou trouba.
    final text = foldText(s.instruction);
    if (t != null &&
        t > best &&
        !text.contains('olej') &&
        !text.contains('lazn') &&
        !text.contains('sous')) {
      best = t.round();
    }
  }
  for (final line in r.temperatures) {
    final text = foldText(line);
    if (!text.contains('troub')) continue;
    for (final m in RegExp(r'(\d{2,3})\s*°').allMatches(text)) {
      final value = int.parse(m.group(1)!);
      if (value > best) best = value;
    }
  }
  return best > 0 ? best : null;
}

/// Kolik litrů hrnce recept potřebuje („aspoň 8–10 l“), nebo null.
double? _neededLitres(Recipe r) {
  for (final line in r.equipment) {
    final text = foldText(line);
    if (!text.contains('hrnec') && !text.contains('hrnc')) continue;
    final match = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(?:(?:–|-|az)\s*\d+(?:[.,]\d+)?\s*)?l\b',
    ).firstMatch(text);
    if (match != null) {
      return double.parse(match.group(1)!.replaceAll(',', '.'));
    }
  }
  return null;
}

/// Posoudí recept podle vybavení uživatele. Bez vybavení vrátí prázdný
/// výsledek (aplikace nic nepředstírá).
EquipmentFit equipmentFit(Recipe recipe, List<Appliance> appliances) {
  if (appliances.isEmpty || recipe.isDeleted) return const EquipmentFit();
  final prep = prepMethodsOf(recipe);
  final text = _recipeText(recipe);
  final tips = <EquipmentTip>[];
  final missing = <String>[];

  Appliance? first(bool Function(Appliance a) test) {
    for (final a in appliances) {
      if (test(a)) return a;
    }
    return null;
  }

  final pizza = text.contains('pizz');
  final oven = first((a) => a.isOven);
  if (prep.contains(PrepMethod.oven) || pizza) {
    if (oven == null) {
      missing.add('Trouba');
    } else {
      final needed = _maxOvenTemperature(recipe);
      final max = oven.maxTemperature;
      if (needed != null && max != null && needed > max) {
        missing.add('Trouba na $needed °C (${oven.name} má nejvýš $max °C)');
      } else {
        tips.add(EquipmentTip(oven.name, 'Pečení v troubě ${oven.name}.'));
      }
      final coreTemp = RegExp(r'uvnitr|vnitrni teplot|jadr|do stredu')
          .hasMatch(text);
      if (oven.hasProbe && coreTemp) {
        tips.add(
          EquipmentTip(
            oven.name,
            'Teplotní sonda trouby pohlídá teplotu uvnitř masa – zapíchněte '
            'ji do nejsilnějšího místa.',
          ),
        );
      }
      final bread = RegExp(
        r'pecivo|chleb|rohlik|bagety|houst|kyn|\bpar[uy]\b|parou',
      ).hasMatch(text);
      if (oven.hasSteam && bread) {
        tips.add(
          EquipmentTip(
            oven.name,
            'SteamAssist: pára na začátku pečení dá pečivu křupavou kůrku.',
          ),
        );
      }
      if (pizza && oven.hasPizzaProgram) {
        tips.add(EquipmentTip(oven.name, 'Trouba má pizza program.'));
      }
    }
  }
  if (pizza) {
    final stone = first((a) => a.isPizzaStone);
    if (stone != null) {
      tips.add(EquipmentTip(stone.name, 'Pizza na kameni: ${stone.name}.'));
    }
  }

  final dough = RegExp(r'hnet|uhnet|zahnet|vyhnet').hasMatch(text);
  if (dough) {
    final mixer = first((a) => a.isMixer);
    if (mixer != null) {
      tips.add(
        EquipmentTip(mixer.name, 'Těsto může uhníst robot ${mixer.name}.'),
      );
    }
  }

  final needed = _neededLitres(recipe);
  if (prep.contains(PrepMethod.pot) || needed != null) {
    final pots = [
      for (final a in appliances)
        if (a.isPot) a,
    ];
    final big = [
      for (final p in pots)
        if (needed == null || (p.litres ?? 0) >= needed) p,
    ];
    if (pots.isNotEmpty && big.isEmpty && needed != null) {
      final biggest = pots.first;
      missing.add(
        'Hrnec aspoň ${needed.toStringAsFixed(needed % 1 == 0 ? 0 : 1)} l '
        '(${biggest.name} je menší)',
      );
    } else if (big.isNotEmpty) {
      tips.add(EquipmentTip(big.first.name, 'Hrnec: ${big.first.name}.'));
    }
  }
  if (prep.contains(PrepMethod.slow) || prep.contains(PrepMethod.pot)) {
    final multi = first((a) => a.isMultiCooker);
    if (multi != null &&
        (prep.contains(PrepMethod.slow) || text.contains('dus'))) {
      tips.add(
        EquipmentTip(
          multi.name,
          multi.isPressure || text.contains('tlak')
              ? 'Jde i v multifunkčním hrnci ${multi.name} – podle receptu '
                    'i pod tlakem.'
              : 'Jde i v multifunkčním hrnci ${multi.name}.',
        ),
      );
    }
  }
  if (prep.contains(PrepMethod.pan)) {
    final pan = first((a) => a.isPan);
    if (pan != null) tips.add(EquipmentTip(pan.name, 'Pánev: ${pan.name}.'));
  }
  if (prep.contains(PrepMethod.waffle) && first((a) => a.isWaffle) == null) {
    missing.add('Vaflovač');
  }
  if (prep.contains(PrepMethod.sousVide) &&
      first((a) => a.isSousVide) == null) {
    missing.add('Sous-vide ohřívač (vodní lázeň s přesnou teplotou)');
  }
  if (prep.contains(PrepMethod.grill) && first((a) => a.isGrill) == null) {
    tips.add(
      const EquipmentTip(
        '',
        'Gril nemáte v seznamu – poslouží rozpálená pánev nebo gril v troubě.',
      ),
    );
  }
  return EquipmentFit(tips: tips, missing: missing);
}
