/// Výpočet času receptu.
///
/// Rozlišuje **aktivní přípravu** (člověk něco dělá), **vaření/pečení**
/// a **pasivní čekání** (kynutí, marinování, chlazení, odpočinek). Celkový
/// čas je skutečná doba od začátku do stolu – pizza, jejíž těsto kyne
/// 20 hodin, nemá „34 minut“.
///
/// Údaje se berou ze tří zdrojů a kombinují se tak, aby se nic nezapočítalo
/// dvakrát a nic nechybělo:
///  1. časy zadané u receptu (příprava, vaření, čekání),
///  2. časy zadané u jednotlivých kroků,
///  3. text kroků – „nech kynout 20 hodin“ se rozpozná i u starších receptů,
///     které čekání nikde zadané nemají.
///
/// Kroky označené jako souběžné (nebo začínající „mezitím“, „zatímco“…)
/// běží zároveň s předchozím krokem a celkový čas neprodlužují.
///
/// Soubor záměrně nezávisí na Flutteru ani na zbytku aplikace.
library;

import 'kitchen_math.dart' show foldText;

/// Druh kroku z hlediska času.
abstract final class StepKind {
  /// Rozpoznat automaticky z textu kroku.
  static const auto = '';
  static const active = 'active';
  static const cook = 'cook';
  static const passive = 'passive';

  static const values = [auto, active, cook, passive];

  static String normalize(String? value) =>
      values.contains(value) ? value! : auto;
}

/// Krok receptu, jak ho potřebuje výpočet času.
class TimedStep {
  const TimedStep({
    required this.instruction,
    this.durationMinutes,
    this.kind = StepKind.auto,
    this.parallel = false,
    this.temperatureC,
  });

  final String instruction;
  final int? durationMinutes;
  final String kind;
  final bool parallel;

  /// Teplota kroku (trouba, olej, vodní lázeň), je-li zadaná.
  final double? temperatureC;
}

/// Druh kroku, jak se počítá do času. Pečení, dušení nebo vaření je vždy
/// „vaření/pečení“, i když je krok označený jako pasivní (člověk u něj
/// nemusí stát) – jinak by se zároveň započítalo do času vaření u receptu
/// i do čekání a celkový čas by vyšel dvakrát. Pasivní zůstává jen
/// skutečné čekání: kynutí, marinování, chlazení, odpočinek.
String effectiveStepKind(TimedStep step) {
  final kind = StepKind.normalize(step.kind);
  if (kind == StepKind.auto) return inferKind(step.instruction);
  if (kind != StepKind.passive) return kind;
  final text = foldText(step.instruction).replaceAll(_subordinate, ' ');
  if (_passivePattern.hasMatch(text)) return StepKind.passive;
  final hot = (step.temperatureC ?? 0) >= 60;
  if (hot || _cookPattern.hasMatch(text)) return StepKind.cook;
  return StepKind.passive;
}

/// Rozpad času receptu v minutách.
class TimeBreakdown {
  const TimeBreakdown({
    this.active = 0,
    this.cook = 0,
    this.passive = 0,
    this.total = 0,
    this.overlap = 0,
  });

  /// Aktivní příprava.
  final int active;

  /// Vaření, pečení, smažení, grilování.
  final int cook;

  /// Čekání: kynutí, marinování, chlazení, odpočinek.
  final int passive;

  /// Skutečný celkový čas.
  final int total;

  /// Kolik minut běží souběžně (o tolik je celek kratší než prostý součet).
  final int overlap;

  bool get isEmpty => total <= 0;
}

final _passivePattern = RegExp(
  r'(^|[^a-z])('
  r'kyn|vykyn|nakyn|prokyn|kvas|vykvas|zrat|zraj|uzra|vyzra|'
  r'marin(?!ad)|v marinade|naloz|naklad|odlez|ulez|rozlez|'
  r'odpocin|odpociv|odpocn|odstat|nechat stat|nech stat|nechame stat|'
  r'vychlad|zchlad|chladnout|chlad(?!n)|vystyd|ztuhn|tuhn|zatuhn|'
  r'lednic|mrazak|mrazni|zmraz|zamraz|'
  r'namoc|namac|louh|vylouh|nabobtn|bobtn|'
  r'pres noc|do druheho dne|rozmraz|temperov|'
  r'sus(it|i|ime) |usus|proschn|oschn|'
  r'nakypr|odkap|okap'
  r')',
);

final _cookPattern = RegExp(
  r'(^|[^a-z])('
  r'pec(?!iv)|upec|zapec|dopec|predpec|opec|opek|'
  r'var(?!iant|ov|uj)|uvar|povar|svar|privar|provar|rozvar|zavar|ovar|predvar|spar|'
  r'dus|podus|udus|smaz|osmaz|usmaz|orestuj|restuj|restov|'
  r'gril|ugril|ud(it|i|ime) |vyud|konfit|sous-vide|sous vide|'
  r'blansir|redukuj|zredukuj|vyvar|tahnout|tahni|probubl|'
  r'v troube|do trouby|na panvi|na plotne|flamb|karameliz|'
  r'tlakov|'
  // Sous-vide a vodní lázeň („ve vodní lázni při 43 °C“), krok s teplotou
  // ohřevu („při 180 °C“) – jde o tepelnou úpravu, ne o práci u linky.
  r'lazn|lazen|°c|° c'
  r')',
);

final _parallelPattern = RegExp(
  r'(^|[^a-z])(mezitim|zatimco|soucasne|zaroven|behem toho|'
  r'behem (peceni|kynuti|vareni|duseni|chlazeni|marinovani|odpocinku|odpocivani)|'
  r'mezi tim|v mezicase|pri tom|pritom)',
);

final _durationPattern = RegExp(
  r'(\d+(?:[.,]\d+)?)\s*(?:(?:–|—|-|az)\s*(\d+(?:[.,]\d+)?)\s*)?'
  r'(hodin[a-z]*|hod\b\.?|h\b|minut[a-z]*|min\b\.?|dn[iyu]\b|dnu\b|den\b|tydn[a-z]*|tyden\b)',
);

final _subordinate = RegExp(r'(zatimco|behem|mezitim co)[^,]*,');

/// Rozpozná druh kroku z textu. Čekání má přednost před vařením – „nech
/// vychladnout a upeč“ bez časů je sporné, ale čekání bývá to delší.
/// Vedlejší věta „zatímco se maso peče, …“ jen říká, kdy se krok dělá,
/// proto se do rozpoznání nepočítá.
String inferKind(String instruction) {
  final text = foldText(instruction).replaceAll(_subordinate, ' ');
  if (_passivePattern.hasMatch(text)) return StepKind.passive;
  if (_cookPattern.hasMatch(text)) return StepKind.cook;
  return StepKind.active;
}

/// Začíná krok slovem, které říká, že běží souběžně s předchozím?
bool inferParallel(String instruction) =>
    _parallelPattern.hasMatch(foldText(instruction));

/// Všechny doby zmíněné v textu, v minutách. U rozsahu („20–24 hodin“) se
/// bere dolní mez – recept má být hotový nejdřív za tuto dobu.
List<int> _durationsIn(String foldedText) {
  final result = <int>[];
  for (final match in _durationPattern.allMatches(foldedText)) {
    final value = double.parse(match.group(1)!.replaceAll(',', '.'));
    final unit = match.group(3)!;
    final factor = unit.startsWith('h')
        ? 60
        : unit.startsWith('m')
        ? 1
        : unit.startsWith('t')
        ? 7 * 24 * 60
        : 24 * 60;
    result.add((value * factor).round());
  }
  var text = foldedText;
  void word(RegExp pattern, int minutes) {
    if (pattern.hasMatch(text)) {
      result.add(minutes);
      text = text.replaceAll(pattern, ' ');
    }
  }

  word(RegExp(r'pres noc|do druheho dne|do rana'), 8 * 60);
  word(RegExp(r'pul ?hodin'), 30);
  word(RegExp(r'ctvrt ?hodin'), 15);
  word(RegExp(r'(^|[^a-z0-9] ?)(hodinu|hodinku)'), 60);
  word(RegExp(r'cely den'), 24 * 60);
  return result;
}

// Čárka a tečka uvnitř čísla („1,5 hodiny“) větu nedělí.
final _clauseSplit = RegExp(
  r'[;!?]|(?<!\d)[.,]|[.,](?!\d)| pak | pote | potom | nasledne ',
);

/// Časy vyčtené z textu jednoho kroku: kolik je čekání a kolik vaření.
({int passive, int cook}) parseStepText(String instruction) {
  var passive = 0;
  var cook = 0;
  var previous = StepKind.active;
  for (final clause in foldText(instruction).split(_clauseSplit)) {
    final text = ' ${clause.trim()} ';
    if (text.trim().isEmpty) continue;
    var kind = _passivePattern.hasMatch(text)
        ? StepKind.passive
        : _cookPattern.hasMatch(text)
        ? StepKind.cook
        : StepKind.active;
    final durations = _durationsIn(text);
    // Věta bez slovesa („pak 2 hodiny při pokojové teplotě“) navazuje na
    // činnost z předchozí věty.
    if (kind == StepKind.active && durations.isNotEmpty) kind = previous;
    final sum = durations.fold<int>(0, (a, b) => a + b);
    if (kind == StepKind.passive) passive += sum;
    if (kind == StepKind.cook) cook += sum;
    if (kind != StepKind.active) previous = kind;
  }
  return (passive: passive, cook: cook);
}

class _Resolved {
  _Resolved({required this.parallel});

  int active = 0;
  int cook = 0;
  int passive = 0;
  final bool parallel;

  int get duration => active + cook + passive;
}

_Resolved _resolve(TimedStep step) {
  final resolved = _Resolved(
    parallel: step.parallel || inferParallel(step.instruction),
  );
  final explicit = step.durationMinutes;
  final kind = StepKind.normalize(step.kind);
  if (explicit != null && explicit > 0) {
    switch (effectiveStepKind(step)) {
      case StepKind.passive:
        resolved.passive = explicit;
      case StepKind.cook:
        resolved.cook = explicit;
      default:
        resolved.active = explicit;
    }
    return resolved;
  }
  // Krok bez zadaného času: čekání a vaření se zkusí vyčíst z textu.
  final parsed = parseStepText(step.instruction);
  if (kind == StepKind.active) return resolved;
  if (kind == StepKind.passive) {
    resolved.passive = parsed.passive + parsed.cook;
  } else if (kind == StepKind.cook) {
    resolved.cook = parsed.passive + parsed.cook;
  } else {
    resolved.passive = parsed.passive;
    resolved.cook = parsed.cook;
  }
  return resolved;
}

/// Spočítá rozpad času receptu.
///
/// [prepMinutes], [cookMinutes] a [restMinutes] jsou časy zadané u receptu.
/// [totalOverride] je ručně zadaný celkový čas; když je větší než nula,
/// použije se místo vypočteného celku.
TimeBreakdown computeRecipeTime({
  int prepMinutes = 0,
  int cookMinutes = 0,
  int restMinutes = 0,
  int totalOverride = 0,
  List<TimedStep> steps = const [],
}) {
  var stepActive = 0;
  var stepCook = 0;
  var stepPassive = 0;
  var sequential = 0; // součet délek kroků, kdyby šly za sebou
  var timeline = 0; // skutečná délka se souběžnými kroky
  var block = 0; // délka právě běžícího bloku souběžných kroků

  for (final step in steps) {
    final resolved = _resolve(step);
    final duration = resolved.duration;
    if (duration <= 0) continue;
    stepActive += resolved.active;
    stepCook += resolved.cook;
    stepPassive += resolved.passive;
    sequential += duration;
    if (resolved.parallel && block > 0) {
      // Běží zároveň s předchozím blokem: prodlouží ho jen o to, oč přesahuje.
      if (duration > block) {
        timeline += duration - block;
        block = duration;
      }
    } else {
      timeline += duration;
      block = duration;
    }
  }
  final overlap = sequential - timeline;

  int max(int a, int b) => a > b ? a : b;
  final active = max(prepMinutes, stepActive);
  final cook = max(cookMinutes, stepCook);
  final passive = max(restMinutes, stepPassive);

  var total = active + cook + passive - overlap;
  // Celek nemůže být kratší než nejdelší jednotlivá část.
  total = max(total, max(active, max(cook, passive)));
  if (totalOverride > 0) total = totalOverride;

  return TimeBreakdown(
    active: active,
    cook: cook,
    passive: passive,
    total: total,
    overlap: totalOverride > 0 ? 0 : overlap,
  );
}

/// Délka slovy: `45 → „45 min“`, `90 → „1 h 30 min“`, `1234 → „20 h 34 min“`,
/// `2940 → „2 dny 1 h“`. Od dvou dnů výš se minuty vynechávají.
String formatDuration(int minutes) {
  if (minutes <= 0) return '0 min';
  if (minutes < 60) return '$minutes min';
  if (minutes < 48 * 60) {
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours h' : '$hours h $rest min';
  }
  final days = minutes ~/ (24 * 60);
  final hours = (minutes % (24 * 60)) ~/ 60;
  final dayWord = days < 5 ? 'dny' : 'dní';
  return hours == 0 ? '$days $dayWord' : '$days $dayWord $hours h';
}
