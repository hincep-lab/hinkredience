import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/recipe_time.dart';

TimedStep s(String text, {int? d, String kind = '', bool par = false}) =>
    TimedStep(instruction: text, durationMinutes: d, kind: kind, parallel: par);

void main() {
  group('celkový čas', () {
    test('pizza: těsto kyne 20 hodin, i když to stojí jen v postupu', () {
      final time = computeRecipeTime(
        prepMinutes: 14,
        cookMinutes: 20,
        steps: [
          s('Smíchej mouku, vodu, sůl a droždí.'),
          s('Těsto nech kynout 20 hodin v lednici.'),
          s('Vytvaruj pizzu a peč na kameni.'),
        ],
      );
      expect(time.active, 14);
      expect(time.cook, 20);
      expect(time.passive, 1200);
      expect(time.total, 1234, reason: 'ne 34 minut');
      expect(formatDuration(time.total), '20 h 34 min');
    });

    test('kuře: 6 hodin nakládání se přičte, pečení jen jednou', () {
      final time = computeRecipeTime(
        prepMinutes: 20,
        cookMinutes: 120,
        steps: [
          s('Kuře potři marinádou a nalož na 6 hodin do lednice.'),
          s('Peč 2 hodiny při 180 °C.'),
        ],
      );
      expect(time.passive, 360);
      expect(time.cook, 120);
      expect(time.total, 500, reason: 'ne 140 minut');
    });

    test('čekání zadané u receptu se s textem kroků nesčítá', () {
      final time = computeRecipeTime(
        prepMinutes: 14,
        cookMinutes: 20,
        restMinutes: 1200,
        steps: [s('Těsto nech kynout 20 hodin v lednici.')],
      );
      expect(time.total, 1234);
    });

    test('bez kroků je to prostý součet', () {
      final time = computeRecipeTime(prepMinutes: 30, cookMinutes: 180);
      expect(time.total, 210);
      expect(time.passive, 0);
      expect(computeRecipeTime().isEmpty, isTrue);
    });

    test('ručně zadaný celkový čas má přednost', () {
      final time = computeRecipeTime(
        prepMinutes: 30,
        cookMinutes: 180,
        totalOverride: 240,
      );
      expect(time.total, 240);
    });
  });

  group('souběžné činnosti', () {
    test('označený krok se nezapočítá dvakrát', () {
      final time = computeRecipeTime(
        steps: [
          s('Maso dej péct.', d: 120, kind: StepKind.cook),
          s('Připrav omáčku.', d: 30, kind: StepKind.active, par: true),
          s('Nech odpočinout.', d: 15),
        ],
      );
      expect(time.active, 30);
      expect(time.cook, 120);
      expect(time.passive, 15);
      expect(time.overlap, 30);
      expect(time.total, 135);
    });

    test('„mezitím“ se pozná z textu', () {
      final time = computeRecipeTime(
        steps: [
          s('Těsto nech kynout 2 hodiny.'),
          s('Mezitím připrav náplň.', d: 20),
          s('Peč 40 minut.'),
        ],
      );
      expect(time.overlap, 20);
      expect(time.total, 160);
    });

    test('delší souběžný krok prodlouží celek jen o rozdíl', () {
      final time = computeRecipeTime(
        steps: [
          s('Krájej zeleninu.', d: 10, kind: StepKind.active),
          s('Vývar táhni.', d: 60, kind: StepKind.cook, par: true),
        ],
      );
      expect(time.total, 60);
    });

    test('„zatímco se maso peče“ je aktivní práce, ne další pečení', () {
      final time = computeRecipeTime(
        prepMinutes: 45,
        steps: [
          s('Peč.', d: 90, kind: StepKind.cook),
          s('Zatímco se maso peče, udělej salát.', d: 15),
        ],
      );
      expect(time.cook, 90);
      expect(time.total, 120);
    });
  });

  group('čtení časů z textu', () {
    test('různé zápisy čekání', () {
      expect(parseStepText('Nech přes noc marinovat.').passive, 480);
      expect(parseStepText('Těsto nech 20–24 hodin kynout.').passive, 1200);
      expect(parseStepText('Nech kynout 1,5 hodiny.').passive, 90);
      expect(parseStepText('Dej na půl hodiny do lednice.').passive, 30);
      expect(parseStepText('Nech hodinu odpočinout.').passive, 60);
      expect(parseStepText('Maso nalož na 2 dny.').passive, 2880);
      expect(parseStepText('Nech v marinádě 6 hodin.').passive, 360);
      expect(
        parseStepText(
          'V lednici nech 20 hodin, pak 2 hodiny při pokojové teplotě.',
        ).passive,
        1320,
      );
    });

    test('čekání a vaření v jednom kroku se rozdělí', () {
      final parsed = parseStepText(
        'Nech 10 minut odpočinout, pak peč 20 minut.',
      );
      expect(parsed.passive, 10);
      expect(parsed.cook, 20);
      expect(parseStepText('Zavařuj 20 min při 85 °C.').cook, 20);
    });

    test('čísla, která nejsou čas, se nepočítají', () {
      expect(parseStepText('Nakrájej cibuli na 5 mm kostičky.').passive, 0);
      expect(parseStepText('Osol 10 g soli a promíchej 2 minuty.').passive, 0);
      expect(parseStepText('Vychlaď a podávej.').passive, 0);
    });

    test('rozpoznání druhu kroku', () {
      expect(inferKind('Nech těsto vykynout.'), StepKind.passive);
      expect(inferKind('Dej chladit.'), StepKind.passive);
      expect(inferKind('Opeč maso ze všech stran.'), StepKind.cook);
      expect(inferKind('Nakrájej pečivo.'), StepKind.active);
      expect(inferKind('Přidej speciální koření.'), StepKind.active);
      expect(inferKind('Vmíchej marinádu.'), StepKind.active);
      expect(inferKind('Zalij chladnou vodou.'), StepKind.active);
      expect(inferKind('Zkus variantu s medem.'), StepKind.active);
      expect(inferParallel('Mezitím uvař brambory.'), isTrue);
      expect(inferParallel('Uvař brambory.'), isFalse);
    });

    test('ručně zvolený druh kroku má přednost před textem', () {
      expect(
        computeRecipeTime(steps: [s('Hotovo.', d: 30, kind: StepKind.passive)])
            .passive,
        30,
      );
      expect(
        computeRecipeTime(
          steps: [s('Nech kynout 20 hodin.', kind: StepKind.active)],
        ).total,
        0,
      );
    });
  });

  test('formatDuration', () {
    expect(formatDuration(0), '0 min');
    expect(formatDuration(45), '45 min');
    expect(formatDuration(60), '1 h');
    expect(formatDuration(90), '1 h 30 min');
    expect(formatDuration(1500), '25 h');
    expect(formatDuration(2940), '2 dny 1 h');
    expect(formatDuration(7200), '5 dní');
  });

  test('vodní lázeň a krok s teplotou jsou vaření, ne ruční práce', () {
    expect(
      inferKind('Připravujte ve vodní lázni při 43 °C po dobu 30 minut.'),
      StepKind.cook,
    );
    expect(inferKind('Nechte vychladnout na 4 °C.'), StepKind.passive);
    final time = computeRecipeTime(
      prepMinutes: 10,
      cookMinutes: 32,
      steps: const [
        TimedStep(
          instruction: 'Připravujte ve vodní lázni při 43 °C po dobu 30 minut.',
          durationMinutes: 30,
        ),
        TimedStep(
          instruction: 'Krátce opečte na rozpálené pánvi.',
          durationMinutes: 2,
        ),
      ],
    );
    expect(time.active, 10);
    expect(time.cook, 32);
    expect(time.total, 42);
  });

  test('pečení označené jako pasivní se nepočítá dvakrát (Carnitas)', () {
    // Recept má 210 min vaření a kroky „Pečte 2 hodiny“ jsou označené jako
    // pasivní – dřív se přičetly ještě jednou jako čekání (7 h místo 4 h).
    final time = computeRecipeTime(
      prepMinutes: 20,
      cookMinutes: 210,
      steps: const [
        TimedStep(
          instruction: 'Maso osolte a potřete kořením.',
          durationMinutes: 10,
          kind: StepKind.active,
        ),
        TimedStep(
          instruction: 'Pečte v troubě na 160 °C 2 hodiny.',
          durationMinutes: 120,
          kind: StepKind.passive,
          temperatureC: 160,
        ),
        TimedStep(
          instruction: 'Alobal sundejte a pečte dalších 60–90 minut.',
          durationMinutes: 75,
          kind: StepKind.passive,
          temperatureC: 160,
        ),
        TimedStep(
          instruction: 'Maso natrhejte a opečte na pánvi dokřupava.',
          durationMinutes: 10,
          kind: StepKind.cook,
        ),
      ],
    );
    expect(time.passive, 0);
    expect(time.cook, 210);
    expect(time.total, 230);
  });

  test('marinování zůstává pasivní, dušení pod pokličkou je vaření', () {
    expect(
      effectiveStepKind(
        const TimedStep(
          instruction: 'Nechte v lednici marinovat 3 hodiny.',
          kind: StepKind.passive,
        ),
      ),
      StepKind.passive,
    );
    expect(
      effectiveStepKind(
        const TimedStep(
          instruction: 'Přikryjte a duste 10 minut.',
          kind: StepKind.passive,
        ),
      ),
      StepKind.cook,
    );
    expect(
      effectiveStepKind(
        const TimedStep(
          instruction: 'Nechte 10 minut odpočinout.',
          kind: StepKind.passive,
        ),
      ),
      StepKind.passive,
    );
    // Marináda 24 h + pečení + odpočinek: nic se nezapočítá dvakrát.
    final charSiu = computeRecipeTime(
      prepMinutes: 10,
      cookMinutes: 90,
      restMinutes: 1440,
      steps: const [
        TimedStep(
          instruction: 'Nechte v lednici 24–48 hodin.',
          durationMinutes: 1440,
          kind: StepKind.passive,
        ),
        TimedStep(
          instruction: 'Pečte 90 minut, potírejte glazurou.',
          durationMinutes: 90,
          kind: StepKind.passive,
          temperatureC: 160,
        ),
        TimedStep(
          instruction: 'Nechte 10 minut odpočinout.',
          durationMinutes: 10,
          kind: StepKind.passive,
        ),
      ],
    );
    expect(charSiu.cook, 90);
    expect(charSiu.passive, 1450);
    expect(charSiu.total, 10 + 90 + 1450);
  });

  test('souběžný krok neprodlouží celkový čas', () {
    final time = computeRecipeTime(
      steps: [
        s('Brambory vařte doměkka.', d: 25, kind: StepKind.cook),
        s('Mezitím opečte maso.', d: 15, kind: StepKind.cook),
        s('Podávejte.', d: 2),
      ],
    );
    expect(time.cook, 40);
    expect(time.overlap, 15);
    expect(time.total, 27);
  });
}
