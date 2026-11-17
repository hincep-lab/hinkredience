import '../../core/app_colors.dart';
import '../../core/conversions.dart';
import '../../core/kitchen_math.dart';
import '../../core/material.dart';
import '../../core/widgets.dart';

/// Převody v kuchyni: odměrky ↔ gramy podle suroviny, teploty trouby
/// (°F, horkovzduch, plyn) a americké váhy.
class ConverterScreen extends StatefulWidget {
  const ConverterScreen({super.key});

  @override
  State<ConverterScreen> createState() => _ConverterScreenState();
}

class _ConverterScreenState extends State<ConverterScreen> {
  final _amount = TextEditingController(text: '1');
  final _temp = TextEditingController(text: '180');
  final _weight = TextEditingController(text: '8');
  String _unit = volumeUnits.keys.first;
  String _ingredient = ingredientDensity.keys.first;
  String _weightUnit = weightUnits.keys.first;
  bool _fahrenheit = false;

  double? _num(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  @override
  void dispose() {
    _amount.dispose();
    _temp.dispose();
    _weight.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = _num(_amount);
    final grams = amount == null ? null : toGrams(amount, _unit, _ingredient);
    final temp = _num(_temp);
    final celsius = temp == null
        ? null
        : _fahrenheit
        ? fahrenheitToCelsius(temp)
        : temp;
    final weight = _num(_weight);
    const muted = TextStyle(color: AppColors.textSecondary, fontSize: 13);
    const big = TextStyle(
      fontSize: 26,
      fontWeight: FontWeight.w700,
      color: AppColors.copperGold,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Převody')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const SectionTitle('Hrnky a lžíce na gramy'),
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _amount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Kolik'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _unit,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Odměrka'),
                        items: [
                          for (final u in volumeUnits.keys)
                            DropdownMenuItem(value: u, child: Text(u)),
                        ],
                        onChanged: (v) => setState(() => _unit = v ?? _unit),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _ingredient,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Surovina'),
                  items: [
                    for (final i in ingredientDensity.keys)
                      DropdownMenuItem(value: i, child: Text(i)),
                  ],
                  onChanged: (v) =>
                      setState(() => _ingredient = v ?? _ingredient),
                ),
                const SizedBox(height: 14),
                Text(
                  grams == null ? '–' : '≈ ${formatConverted(grams)} g',
                  style: big,
                ),
                if (grams != null)
                  Text(
                    [
                      for (final u in const [
                        'hrnek (250 ml)',
                        'lžíce',
                        'lžička',
                      ])
                        if (u != _unit)
                          '${formatConverted(fromGrams(grams, u, _ingredient)!, grams: false)} $u',
                    ].join(' · '),
                    style: muted,
                  ),
                const SizedBox(height: 4),
                const Text(
                  'Sypké suroviny se liší podle nabírání – berte jako '
                  'kuchyňský odhad.',
                  style: muted,
                ),
              ],
            ),
          ),

          const SectionTitle('Teplota trouby'),
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _temp,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Teplota',
                          suffixText: _fahrenheit ? '°F' : '°C',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('°C')),
                        ButtonSegment(value: true, label: Text('°F')),
                      ],
                      selected: {_fahrenheit},
                      onSelectionChanged: (v) =>
                          setState(() => _fahrenheit = v.first),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (celsius != null) ...[
                  Text(
                    _fahrenheit
                        ? '${formatNumber(celsius.roundToDouble(), decimals: 0)} °C'
                        : '${formatNumber(celsiusToFahrenheit(celsius).roundToDouble(), decimals: 0)} °F',
                    style: big,
                  ),
                  Text(
                    'Horkovzduch: ${formatNumber(fanFromConventional(celsius).roundToDouble(), decimals: 0)} °C '
                    '(horní/spodní ohřev ${formatNumber(celsius.roundToDouble(), decimals: 0)} °C)',
                    style: muted,
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in gasMarks.entries)
                      Chip(label: Text('Plyn ${e.key} = ${e.value} °C')),
                  ],
                ),
              ],
            ),
          ),

          const SectionTitle('Unce a libry'),
          HkCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _weight,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(labelText: 'Kolik'),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _weightUnit,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Jednotka',
                        ),
                        items: [
                          for (final u in weightUnits.keys)
                            DropdownMenuItem(value: u, child: Text(u)),
                        ],
                        onChanged: (v) =>
                            setState(() => _weightUnit = v ?? _weightUnit),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  weight == null
                      ? '–'
                      : '${formatConverted(weight * weightUnits[_weightUnit]!)} g',
                  style: big,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
