/// Orientační teploty jádra a sous-vide časy pro domácí kuchyni.
///
/// Hodnoty jsou běžně uváděné kuchařské doporučení (u drůbeže a mletého
/// masa s bezpečnou rezervou). Čas sous-vide platí pro uvedenou tloušťku –
/// silnější kus potřebuje víc času na prohřátí.
class TemperatureGuide {
  const TemperatureGuide({
    required this.group,
    required this.name,
    required this.coreC,
    this.doneness = '',
    this.sousVideC,
    this.sousVideMinutes,
    this.thickness = '',
    this.note = '',
  });

  final String group;
  final String name;

  /// Teplota jádra (sonda v troubě, vpichový teploměr).
  final int coreC;
  final String doneness;
  final double? sousVideC;
  final int? sousVideMinutes;
  final String thickness;
  final String note;
}

const temperatureGuides = <TemperatureGuide>[
  // Hovězí
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Steak',
    doneness: 'krvavý (rare)',
    coreC: 52,
    sousVideC: 52,
    sousVideMinutes: 90,
    thickness: '2,5 cm',
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Steak',
    doneness: 'medium rare',
    coreC: 56,
    sousVideC: 56,
    sousVideMinutes: 90,
    thickness: '2,5 cm',
    note: 'Po sous-vide krátce opéct na rozpálené pánvi.',
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Steak',
    doneness: 'medium',
    coreC: 60,
    sousVideC: 60,
    sousVideMinutes: 90,
    thickness: '2,5 cm',
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Steak',
    doneness: 'propečený',
    coreC: 70,
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Roastbeef',
    doneness: 'růžový',
    coreC: 56,
    sousVideC: 56,
    sousVideMinutes: 360,
    thickness: '7 cm',
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Svíčková (zadní) na smetaně',
    doneness: 'měkká',
    coreC: 85,
    note: 'Dusit pomalu, až je maso měkké (cca 2–3 h).',
  ),
  TemperatureGuide(
    group: 'Hovězí',
    name: 'Hovězí líčka / žebra',
    doneness: 'rozpadající se',
    coreC: 90,
    sousVideC: 68,
    sousVideMinutes: 2160,
    note: 'Sous-vide 36 h, nebo dusit 3–4 h.',
  ),
  // Vepřové
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Panenka',
    doneness: 'šťavnatá, lehce růžová',
    coreC: 62,
    sousVideC: 60,
    sousVideMinutes: 120,
    thickness: '5 cm',
  ),
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Kotleta',
    doneness: 'šťavnatá',
    coreC: 63,
    sousVideC: 60,
    sousVideMinutes: 90,
    thickness: '2,5 cm',
  ),
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Krkovice – plátky',
    doneness: 'propečené',
    coreC: 68,
  ),
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Trhané maso (pulled pork)',
    doneness: 'rozpadající se',
    coreC: 93,
    sousVideC: 74,
    sousVideMinutes: 1440,
    note: 'V troubě 110–120 °C několik hodin, až jádro dosáhne 90–95 °C.',
  ),
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Bůček',
    doneness: 'měkký',
    coreC: 80,
    sousVideC: 70,
    sousVideMinutes: 1440,
    note: 'Kůži nakonec dopéct na prudko (grill).',
  ),
  TemperatureGuide(
    group: 'Vepřové',
    name: 'Žebra',
    doneness: 'měkká',
    coreC: 90,
    sousVideC: 68,
    sousVideMinutes: 1440,
  ),
  // Drůbež
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Kuřecí prsa',
    doneness: 'šťavnatá',
    coreC: 72,
    sousVideC: 63,
    sousVideMinutes: 120,
    thickness: '3 cm',
    note: 'Klasicky do 72 °C v jádře; sous-vide 63 °C min. 2 h.',
  ),
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Kuřecí stehna',
    doneness: 'propečená',
    coreC: 80,
    sousVideC: 74,
    sousVideMinutes: 180,
  ),
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Celé kuře',
    doneness: 'propečené',
    coreC: 78,
    note: 'Měřit v nejsilnějším místě stehna, mimo kost.',
  ),
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Kachní prsa',
    doneness: 'růžová',
    coreC: 58,
    sousVideC: 57,
    sousVideMinutes: 120,
    note: 'Kůži nakonec opéct dokřupava.',
  ),
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Kachní stehna (konfit)',
    doneness: 'měkká',
    coreC: 85,
    sousVideC: 80,
    sousVideMinutes: 720,
  ),
  TemperatureGuide(
    group: 'Drůbež',
    name: 'Krůtí prsa',
    doneness: 'šťavnatá',
    coreC: 72,
    sousVideC: 63,
    sousVideMinutes: 180,
    thickness: '4 cm',
  ),
  // Ostatní maso
  TemperatureGuide(
    group: 'Ostatní maso',
    name: 'Mleté maso, karbanátky',
    doneness: 'propečené',
    coreC: 72,
    note: 'Mleté maso vždy propéct.',
  ),
  TemperatureGuide(
    group: 'Ostatní maso',
    name: 'Jehněčí kotletky',
    doneness: 'růžové',
    coreC: 58,
    sousVideC: 57,
    sousVideMinutes: 90,
  ),
  TemperatureGuide(
    group: 'Ostatní maso',
    name: 'Králík',
    doneness: 'propečený',
    coreC: 72,
    sousVideC: 65,
    sousVideMinutes: 240,
  ),
  TemperatureGuide(
    group: 'Ostatní maso',
    name: 'Zvěřina – hřbet',
    doneness: 'růžový',
    coreC: 58,
    sousVideC: 56,
    sousVideMinutes: 120,
  ),
  // Ryby
  TemperatureGuide(
    group: 'Ryby',
    name: 'Losos',
    doneness: 'sklovitý',
    coreC: 50,
    sousVideC: 50,
    sousVideMinutes: 40,
    thickness: '2,5 cm',
  ),
  TemperatureGuide(
    group: 'Ryby',
    name: 'Treska, candát',
    doneness: 'tak akorát',
    coreC: 55,
    sousVideC: 55,
    sousVideMinutes: 30,
  ),
  TemperatureGuide(
    group: 'Ryby',
    name: 'Pstruh celý',
    doneness: 'propečený',
    coreC: 60,
  ),
  // Ostatní
  TemperatureGuide(
    group: 'Vejce a zelenina',
    name: 'Vejce „63 °C“',
    doneness: 'krémový žloutek',
    coreC: 63,
    sousVideC: 63,
    sousVideMinutes: 45,
  ),
  TemperatureGuide(
    group: 'Vejce a zelenina',
    name: 'Mrkev, kořenová zelenina',
    doneness: 'al dente',
    coreC: 85,
    sousVideC: 85,
    sousVideMinutes: 60,
  ),
  TemperatureGuide(
    group: 'Vejce a zelenina',
    name: 'Chléb (kvasový)',
    doneness: 'upečený',
    coreC: 96,
    note: 'Měřit uprostřed bochníku.',
  ),
];

/// Skupiny v pořadí, v jakém se mají zobrazit.
List<String> get temperatureGroups => [
  for (final guide in temperatureGuides)
    if (guide == temperatureGuides.firstWhere((g) => g.group == guide.group))
      guide.group,
];

/// „1 h 30 min“, „24 h“, „45 min“.
String formatGuideMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '$h h';
  return '$h h $m min';
}
