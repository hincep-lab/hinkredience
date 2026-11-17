/// Kuchyňské převody: hrnky a lžíce na gramy podle suroviny, teploty
/// trouby, americké a britské jednotky. Hodnoty jsou běžné kuchyňské
/// průměry (sypké suroviny se liší podle toho, jak se nabírají).
library;

import 'kitchen_math.dart';

/// Odměrky (objem v ml).
const volumeUnits = <String, double>{
  'hrnek (250 ml)': 250,
  'US cup (240 ml)': 240,
  'lžíce': 15,
  'lžička': 5,
  'ml': 1,
  'dl': 100,
  'fl oz (US)': 29.57,
};

/// Hmotnost 1 ml suroviny v gramech (hustota při běžném nabírání).
const ingredientDensity = <String, double>{
  'Mouka hladká': 0.56,
  'Mouka polohrubá': 0.6,
  'Mouka hrubá': 0.66,
  'Cukr krupice': 0.8,
  'Cukr moučka': 0.5,
  'Máslo': 0.95,
  'Olej': 0.92,
  'Voda': 1.0,
  'Mléko': 1.03,
  'Smetana': 1.0,
  'Med': 1.42,
  'Sůl': 1.2,
  'Rýže': 0.8,
  'Ovesné vločky': 0.36,
  'Kakao': 0.42,
  'Strouhanka': 0.45,
  'Mák mletý': 0.55,
  'Ořechy mleté': 0.48,
};

/// Gramy pro [amount] odměrky [unit] suroviny [ingredient].
double? toGrams(double amount, String unit, String ingredient) {
  final ml = volumeUnits[unit];
  final density = ingredientDensity[ingredient];
  if (ml == null || density == null || amount < 0) return null;
  return amount * ml * density;
}

/// Kolik odměrek [unit] je [grams] gramů suroviny [ingredient].
double? fromGrams(double grams, String unit, String ingredient) {
  final ml = volumeUnits[unit];
  final density = ingredientDensity[ingredient];
  if (ml == null || density == null || grams < 0) return null;
  return grams / (ml * density);
}

double celsiusToFahrenheit(double c) => c * 9 / 5 + 32;
double fahrenheitToCelsius(double f) => (f - 32) * 5 / 9;

/// Horkovzduch peče rychleji: obvykle o 20 °C méně než horní/spodní ohřev.
double fanFromConventional(double c) => c - 20;

/// Plynová trouba (stupeň) → °C.
const gasMarks = <int, int>{
  1: 140,
  2: 150,
  3: 170,
  4: 180,
  5: 190,
  6: 200,
  7: 220,
  8: 230,
  9: 240,
};

/// Hmotnost: americké a britské jednotky na gramy.
const weightUnits = <String, double>{
  'oz (unce)': 28.35,
  'lb (libra)': 453.6,
  'stick másla (US)': 113.4,
};

/// Číslo pro kuchyň: gramy na celé (pod 10 g na desetiny), odměrky
/// zlomkem („½ hrnku“).
String formatConverted(double value, {bool grams = true}) {
  if (grams) {
    return value >= 10
        ? formatNumber(value.roundToDouble(), decimals: 0)
        : formatNumber(value, decimals: 1);
  }
  return formatFraction(value);
}
