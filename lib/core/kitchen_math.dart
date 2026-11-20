/// Kuchyňská matematika: přepočet množství na jiný počet porcí tak, aby
/// výsledek šel v kuchyni opravdu odměřit.
///
/// - gramy a mililitry se zaokrouhlují podle velikosti (nikdo neváží 283,33 g),
/// - lžíce, hrnky a kusy se zobrazují jako kuchyňské zlomky (½, ⅓, ¼…),
/// - vejce se přepočítávají na celé kusy,
/// - rozsahy v poznámkách („2–3 lžíce“) se přepočítají také.
///
/// Soubor záměrně nezávisí na Flutteru ani na zbytku aplikace.
library;

/// Druh jednotky – určuje, jak se množství zaokrouhluje a zobrazuje.
enum UnitKind {
  /// g, dkg, kg
  mass,

  /// ml, cl, dl, l
  volume,

  /// lžíce, lžička, hrnek, šálek, špetka… – měří se odměrkou
  measure,

  /// ks, stroužek, plátek, vejce… – počítá se na kusy
  count,

  /// neznámá jednotka
  other,
}

const _diacritics = 'áäčďéěíĺľňóôöŕřšťúůüýž';
const _plain = 'aacdeeillnooorrstuuuyz';

/// Malými písmeny a bez diakritiky.
String foldText(String input) {
  final buffer = StringBuffer();
  for (final rune in input.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final index = _diacritics.indexOf(char);
    buffer.write(index >= 0 ? _plain[index] : char);
  }
  return buffer.toString();
}

const _massUnits = {'g': 1.0, 'dkg': 10.0, 'dag': 10.0, 'kg': 1000.0};
const _volumeUnits = {'ml': 1.0, 'cl': 10.0, 'dl': 100.0, 'l': 1000.0};

const _measureStems = [
  'lzic', // lžíce, lžička, lžic, lžičky
  'pl',
  'kl',
  'hrnek',
  'hrnk',
  'hrnec',
  'salek',
  'salk',
  'sklenic',
  'sklenk',
  'spetk',
  'hrst',
  'odmerk',
  'kapk',
  'cup',
  'tbsp',
  'tsp',
];

const _countStems = [
  'ks',
  'kus',
  'vejce',
  'vajec',
  'vajic',
  'zloutk',
  'zloutek',
  'bilk',
  'bilek',
  'strouz',
  'platk',
  'platek',
  'list',
  'snitk',
  'svaz',
  'balen',
  'balic',
  'plechov',
  'konzerv',
  'hlav',
  'palic',
  'kelimk',
  'kelimek',
  'kostk',
  'sack',
  'sacek',
  'lahv',
  'lahev',
  'tabulk',
  'kolec',
  'rohlik',
  'housk',
  'krajic',
  'stonk',
  'stonek',
  'lusk',
  'lusek',
  'tycink',
  'filet',
  'steh',
  'prs',
  'kridl',
  'kotlet',
  'rizk',
  'porc',
];

/// Rozpozná druh jednotky. Prázdná jednotka se bere jako kusy.
UnitKind unitKind(String unit) {
  final folded = foldText(unit.trim());
  if (folded.isEmpty) return UnitKind.count;
  final bare = folded.endsWith('.')
      ? folded.substring(0, folded.length - 1)
      : folded;
  // „čl“ (čajová lžička) po odstranění diakritiky koliduje s „cl“ (centilitr),
  // proto se rozlišuje ještě před ním.
  final lower = unit.trim().toLowerCase();
  if (lower == 'čl' || lower == 'čl.') return UnitKind.measure;
  if (_massUnits.containsKey(bare)) return UnitKind.mass;
  if (_volumeUnits.containsKey(bare)) return UnitKind.volume;
  for (final stem in _measureStems) {
    if (bare == stem || (stem.length > 2 && bare.startsWith(stem))) {
      return UnitKind.measure;
    }
  }
  for (final stem in _countStems) {
    if (bare == stem || (stem.length > 2 && bare.startsWith(stem))) {
      return UnitKind.count;
    }
  }
  return UnitKind.other;
}

/// Vejce, žloutky a bílky – přepočítávají se jen na celé kusy.
bool isEggLike(String name, [String unit = '']) {
  final text = ' ${foldText('$name $unit')} ';
  return RegExp(
    r'[^a-z](vejce|vajec|vejci|vajic|vajick|zloutk|zloutek|bilk|bilek)',
  ).hasMatch(text);
}

/// Číslo po česku: desetinná čárka, nejvýše [decimals] míst, bez koncových nul.
String formatNumber(double value, {int decimals = 2}) {
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  }
  if (text == '-0') text = '0';
  return text.replaceAll('.', ',');
}

double _roundTo(double value, double step) => (value / step).round() * step;

/// Zaokrouhlí hmotnost v gramech nebo objem v mililitrech na hodnotu, která
/// jde rozumně odměřit. Čím větší množství, tím hrubší krok.
double roundMetric(double base) {
  if (base <= 0) return 0;
  double rounded;
  if (base < 1) {
    rounded = _roundTo(base, 0.1);
    if (rounded <= 0) rounded = 0.1;
  } else if (base < 10) {
    rounded = _roundTo(base, 0.5);
  } else if (base < 100) {
    rounded = _roundTo(base, 1);
  } else if (base < 500) {
    rounded = _roundTo(base, 5);
  } else if (base < 2000) {
    rounded = _roundTo(base, 10);
  } else {
    rounded = _roundTo(base, 50);
  }
  // Odstraní chyby plovoucí čárky (např. 0,30000000000000004).
  return (rounded * 10).round() / 10;
}

const _fractions = <(double, String)>[
  (1 / 8, '⅛'),
  (1 / 4, '¼'),
  (1 / 3, '⅓'),
  (1 / 2, '½'),
  (2 / 3, '⅔'),
  (3 / 4, '¾'),
];

/// Zapíše číslo jako kuchyňský zlomek: `1.5 → „1 ½“`, `0.33 → „⅓“`,
/// `2.0 → „2“`. Hodnota se zaokrouhlí na nejbližší běžný zlomek.
/// S [halvesOnly] se používají jen poloviny (pro kusy).
String formatFraction(double value, {bool halvesOnly = false}) {
  if (value <= 0) return '0';
  if (value >= 10) return value.round().toString();
  var whole = value.floor();
  final rest = value - whole;
  final candidates = halvesOnly
      ? const <(double, String)>[(1 / 2, '½')]
      : _fractions;

  var bestValue = 0.0;
  var bestGlyph = '';
  var bestDistance = rest; // vzdálenost k „žádný zlomek“
  for (final (fraction, glyph) in candidates) {
    final distance = (rest - fraction).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      bestValue = fraction;
      bestGlyph = glyph;
    }
  }
  if ((1 - rest) < bestDistance) {
    // Nejblíž je další celé číslo.
    whole += 1;
    bestValue = 0;
    bestGlyph = '';
  }
  if (whole == 0 && bestGlyph.isEmpty) {
    // Nikdy nezaokrouhlujeme na nulu – použijeme nejmenší zlomek.
    return candidates.first.$2;
  }
  if (bestValue == 0) return whole.toString();
  return whole == 0 ? bestGlyph : '$whole $bestGlyph';
}

/// Je číslo (skoro) celé nebo běžný zlomek? Pak ho lze psát zlomkem beze
/// ztráty přesnosti i u nepřepočítaného receptu.
bool _isNiceFraction(double value) {
  final rest = value - value.floorToDouble();
  if (rest < 0.005 || rest > 0.995) return true;
  return _fractions.any((f) => (rest - f.$1).abs() < 0.012);
}

String _withUnit(String amount, String unit) =>
    unit.trim().isEmpty ? amount : '$amount ${unit.trim()}';

/// Množství s jednotkou připravené k zobrazení.
///
/// [factor] je poměr nového a původního počtu porcí. Při `factor == 1` se
/// zobrazí přesně zadaná hodnota (jen hezky zapsaná); jinak se množství
/// přepočítá a chytře zaokrouhlí podle druhu jednotky.
String formatAmount(
  double? quantity,
  String unit, {
  double factor = 1,
  String name = '',
}) {
  if (quantity == null || quantity <= 0) return unit.trim();
  final kind = unitKind(unit);
  final scaled = (factor - 1).abs() > 1e-9;
  final value = quantity * factor;

  if (!scaled) {
    final fractional =
        (kind == UnitKind.measure || kind == UnitKind.count) &&
        _isNiceFraction(value) &&
        value < 10;
    return _withUnit(
      fractional ? formatFraction(value) : formatNumber(value),
      unit,
    );
  }

  switch (kind) {
    case UnitKind.mass:
      return _formatMetric(value, unit, _massUnits, small: 'g', large: 'kg');
    case UnitKind.volume:
      return _formatMetric(value, unit, _volumeUnits, small: 'ml', large: 'l');
    case UnitKind.measure:
      return _withUnit(formatFraction(value), unit);
    case UnitKind.count:
      if (isEggLike(name, unit)) return _formatEggs(value, unit, name);
      return _withUnit(formatFraction(value, halvesOnly: true), unit);
    case UnitKind.other:
      final rounded = value < 10
          ? _roundTo(value, 0.25)
          : value.roundToDouble();
      return _withUnit(formatNumber(rounded <= 0 ? value : rounded), unit);
  }
}

/// Vejce se přepočítávají po polovinách: 3 vejce × 1,5 = „4 ½ ks (4 celá
/// + ½ rozšlehaného)“. Polovina se nikdy potichu nezaokrouhlí na celé vejce.
String _formatEggs(double value, String unit, String name) {
  final halves = (value * 2).round() / 2;
  final shown = halves < 0.5 ? 0.5 : halves;
  final whole = shown.floor();
  final hasHalf = shown - whole > 0.25;
  final notes = <String>[
    if (hasHalf && whole == 0) 'rozšlehejte 1 a použijte polovinu',
    if (hasHalf && whole > 0)
      '$whole ${_wholeWord(whole, '$name $unit')} + ½ rozšlehaného',
    if ((value - shown).abs() / value > 0.1)
      'přesně ${formatNumber(value, decimals: 1)}',
  ];
  final label = _withUnit(formatFraction(shown), unit);
  return notes.isEmpty ? label : '$label (${notes.join(', ')})';
}

/// „celé / celá / celých“ podle počtu a toho, jestli jde o vejce, nebo
/// o žloutky a bílky.
String _wholeWord(int count, String text) {
  final folded = foldText(text);
  final neuter =
      RegExp(r'vejc|vajec|vajic|vejce').hasMatch(folded) ||
      !RegExp(r'zloutk|zloutek|bilk|bilek').hasMatch(folded);
  if (count == 1) return neuter ? 'celé' : 'celý';
  if (count >= 2 && count <= 4) return neuter ? 'celá' : 'celé';
  return 'celých';
}

String _formatMetric(
  double value,
  String unit,
  Map<String, double> table, {
  required String small,
  required String large,
}) {
  final folded = foldText(unit.trim());
  final bare = folded.endsWith('.')
      ? folded.substring(0, folded.length - 1)
      : folded;
  final unitSize = table[bare] ?? 1;
  final base = roundMetric(value * unitSize);

  // Mezilehlé jednotky (dkg, dl, cl) necháváme, jak je uživatel zadal.
  if (unitSize == 10 || unitSize == 100) {
    final inUnit = base / unitSize;
    final rounded = inUnit < 10
        ? _roundTo(inUnit, 0.5)
        : inUnit.roundToDouble();
    return '${formatNumber(rounded <= 0 ? inUnit : rounded)} ${unit.trim()}';
  }
  if (base >= 1000) return '${formatNumber(base / 1000)} $large';
  return '${formatNumber(base, decimals: 1)} $small';
}

/// Převede hmotnost na gramy a objem na mililitry, aby šla množství téže
/// suroviny sčítat (500 g + 1 kg). Ostatní jednotky vrací beze změny.
({double quantity, String unit}) toBaseUnit(double quantity, String unit) {
  final trimmed = unit.trim();
  final folded = foldText(trimmed);
  final bare = folded.endsWith('.')
      ? folded.substring(0, folded.length - 1)
      : folded;
  switch (unitKind(unit)) {
    case UnitKind.mass:
      return (quantity: quantity * (_massUnits[bare] ?? 1), unit: 'g');
    case UnitKind.volume:
      return (quantity: quantity * (_volumeUnits[bare] ?? 1), unit: 'ml');
    case UnitKind.measure:
    case UnitKind.count:
    case UnitKind.other:
      return (quantity: quantity, unit: trimmed);
  }
}

/// Součet množství pro nákupní seznam: gramy a mililitry se zaokrouhlí a od
/// tisíce převedou na kg / l, kusy a lžíce se zapíšou zlomkem.
String formatTotalAmount(double? quantity, String unit) {
  if (quantity == null || quantity <= 0) return unit.trim();
  switch (unitKind(unit)) {
    case UnitKind.mass:
      return _formatMetric(quantity, unit, _massUnits, small: 'g', large: 'kg');
    case UnitKind.volume:
      return _formatMetric(
        quantity,
        unit,
        _volumeUnits,
        small: 'ml',
        large: 'l',
      );
    case UnitKind.measure:
    case UnitKind.count:
      return _withUnit(formatFraction(quantity), unit);
    case UnitKind.other:
      return _withUnit(formatNumber(quantity), unit);
  }
}

// ------------------------------------------------------------ rozsahy v textu

final _rangePattern = RegExp(
  r'(\d+(?:[.,]\d+)?)(\s*(?:–|—|-|až)\s*)(\d+(?:[.,]\d+)?)(\s*)([^\s\d,;.()\[\]]*)',
);

/// Slova za rozsahem, která znamenají čas, teplotu nebo rozměr – ty se
/// s počtem porcí nemění.
bool _isFixedDimension(String word) {
  final folded = foldText(word);
  if (folded.isEmpty) return false;
  return RegExp(
    r'^(°|°c|c$|stupn|min|minut|h$|hod|hodin|s$|sek|vterin|den|dny|dni|dnu|tydn|tyden|cm|mm|m$|%|procent|x$|krat)',
  ).hasMatch(folded);
}

double _parseNumber(String text) => double.parse(text.replaceAll(',', '.'));

/// Přepočítá rozsahy množství v textu, např. „2–3 lžíce“ → „4–6 lžic“.
///
/// - Rozsahy času, teploty a rozměrů („10–15 minut“, „160–170 °C“) nechává být.
/// - [fallbackUnit] se použije pro rozsah bez jednotky („přidej 2–3“).
/// - S [requireUnit] se přepočítají jen rozsahy se známou jednotkou – vhodné
///   pro volný text poznámek, kde číslo může znamenat cokoli.
String scaleRangesInText(
  String text,
  double factor, {
  String fallbackUnit = '',
  String name = '',
  bool requireUnit = false,
}) {
  if ((factor - 1).abs() < 1e-9 || text.isEmpty) return text;
  return text.replaceAllMapped(_rangePattern, (match) {
    final word = match.group(5) ?? '';
    if (_isFixedDimension(word)) return match.group(0)!;
    final wordKind = word.isEmpty ? UnitKind.other : unitKind(word);
    final hasKnownUnit = word.isNotEmpty && wordKind != UnitKind.other;
    if (requireUnit && !hasKnownUnit) return match.group(0)!;
    // Slovo za rozsahem, které není jednotka („2–3 stroužky“ ano, „2–3 dobře
    // vyzrálá rajčata“ ne), k číslu nepatří – použije se náhradní jednotka.
    final unit = hasKnownUnit ? word : fallbackUnit;

    final low = _parseNumber(match.group(1)!);
    final high = _parseNumber(match.group(3)!);
    if (high < low) return match.group(0)!;

    String amount(double value) {
      final label = formatAmount(value, unit, factor: factor, name: name);
      // formatAmount vrací i jednotku; z dolní a horní meze chceme jen číslo.
      final trimmedUnit = unit.trim();
      var number = label;
      final exactIndex = number.indexOf(' (');
      if (exactIndex >= 0) number = number.substring(0, exactIndex);
      if (trimmedUnit.isNotEmpty && number.endsWith(' $trimmedUnit')) {
        number = number.substring(0, number.length - trimmedUnit.length - 1);
      }
      return number;
    }

    final kind = unitKind(unit);
    if (kind == UnitKind.mass || kind == UnitKind.volume) {
      // Metrické jednotky se mohou při přepočtu změnit (g → kg), proto
      // vypíšeme obě meze i s jednotkou z formátovače.
      final lowLabel = formatAmount(low, unit, factor: factor);
      final highLabel = formatAmount(high, unit, factor: factor);
      final lowUnit = lowLabel.split(' ').last;
      final highUnit = highLabel.split(' ').last;
      final lowNumber = lowLabel.substring(
        0,
        lowLabel.length - lowUnit.length - 1,
      );
      return lowUnit == highUnit
          ? '$lowNumber–$highLabel'
          : '$lowLabel – $highLabel';
    }

    final lowText = amount(low);
    final highText = amount(high);
    final space = match.group(4) ?? '';
    final tail = word.isEmpty ? '' : '${space.isEmpty ? '' : ' '}$word';
    if (lowText == highText) return '$lowText$tail';
    return '$lowText–$highText$tail';
  });
}

// ------------------------------------------------------------------ výtěžnost

/// Jednotky výtěžnosti receptu.
abstract final class YieldUnit {
  static const servings = 'porce';
  static const pieces = 'ks';
  static const liters = 'l';
  static const milliliters = 'ml';
  static const grams = 'g';
  static const kilograms = 'kg';

  /// Jednotky druhé varianty výnosu („10 porcí“ ↔ „55 ks“, „4 porce“ ↔
  /// „1 l omáčky“).
  static const variants = [
    servings,
    pieces,
    liters,
    milliliters,
    grams,
    kilograms,
  ];

  /// Sjednotí jednotku druhé varianty; neznámá → null.
  static String? normalizeVariant(String? value) {
    final folded = foldText((value ?? '').trim()).replaceAll('.', '');
    if (folded.isEmpty) return null;
    if (folded == 'ks' || folded.startsWith('kus')) return pieces;
    if (folded.startsWith('porc')) return servings;
    if (folded == 'l' || folded.startsWith('litr')) return liters;
    if (folded == 'ml' || folded.startsWith('mililitr')) return milliliters;
    if (folded == 'g' || folded.startsWith('gram')) return grams;
    if (folded == 'kg' || folded.startsWith('kilo')) return kilograms;
    return null;
  }

  /// Krok tlačítek +/− pro danou jednotku.
  static double step(String unit) => switch (unit) {
    liters || kilograms => 0.25,
    milliliters || grams => 50,
    _ => 1,
  };

  /// Popis do přepínače a tlačítek („kusů“, „litrů“…).
  static String noun(String unit) => switch (unit) {
    pieces => 'kusů',
    liters => 'litrů',
    milliliters => 'mililitrů',
    grams => 'gramů',
    kilograms => 'kilogramů',
    _ => 'porcí',
  };

  /// Sjednotí uloženou hodnotu; prázdná nebo neznámá znamená porce.
  static String normalize(String? value) {
    final folded = foldText((value ?? '').trim());
    if (folded == 'ks' || folded.startsWith('kus')) return pieces;
    return servings;
  }
}

/// Výtěžnost receptu slovy: „4 porce“, „5 porcí“, „1 porce“, „12 ks“.
String yieldLabel(double amount, String unit) {
  final number = formatNumber(amount);
  final variant = YieldUnit.normalizeVariant(unit);
  if (variant != null &&
      variant != YieldUnit.servings &&
      variant != YieldUnit.pieces) {
    return '$number $variant';
  }
  if (YieldUnit.normalize(unit) == YieldUnit.pieces) return '$number ks';
  if (amount == 1) return '$number porce';
  if (amount > 1 && amount < 5 && amount == amount.roundToDouble()) {
    return '$number porce';
  }
  if (amount != amount.roundToDouble()) return '$number porce';
  return '$number porcí';
}
