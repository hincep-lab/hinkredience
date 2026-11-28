import 'kitchen_math.dart';

/// Řádek účtenky: produkt a cena za kus (po slevě).
class ReceiptLine {
  ReceiptLine({
    required this.product,
    required this.price,
    this.packQty,
    this.packUnit = '',
  });

  String product;
  double price;
  double? packQty;
  String packUnit;
}

/// Rozpoznaná účtenka.
class ParsedReceipt {
  const ParsedReceipt({required this.lines, this.storeId, this.date});

  final List<ReceiptLine> lines;
  final String? storeId;
  final DateTime? date;
}

const _skipWords = [
  'celkem',
  'mezisouc',
  'dph',
  'zaklad',
  'karta',
  'hotov',
  'vraceno',
  'zaokrouhl',
  'platba',
  'k uhrade',
  'suma',
  'eet',
  'bkp',
  'fik',
  'total',
  'visa',
  'mastercard',
  'uctenk',
  'pokladn',
  'ic:',
  'dic',
  'dekujeme',
  'zaplaceno',
  'bonus',
  'body',
  'clubcard',
  'terminal',
  'transakc',
];

/// Text účtenky (z fotky nebo z PDF) → položky s cenou, obchod a datum.
/// Nic se nedomýšlí: řádek bez čitelné ceny se vynechá.
ParsedReceipt parseReceiptText(String text) {
  if (_eReceiptLine.hasMatch(text)) {
    final structured = parseEReceiptText(text);
    if (structured.lines.isNotEmpty) return structured;
  }
  final lines = <ReceiptLine>[];
  final item = RegExp(
    r'^(.*?[A-Za-zÀ-ž].*?)\s+(-?\d{1,5}[.,]\d{2})(?:\s*[A-Z]{1,2})?\s*$',
  );
  final multiply = RegExp(
    r'^(\d+(?:[.,]\d+)?)\s*(?:ks\s*)?[x×*]\s*(\d{1,5}[.,]\d{2})',
    caseSensitive: false,
  );
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) continue;
    final folded = foldText(line);
    final mul = multiply.firstMatch(line);
    if (mul != null) {
      // „2 x 21,90“ – cena za kus k předchozí položce.
      if (lines.isNotEmpty) lines.last.price = _num(mul.group(2)!);
      continue;
    }
    if (_skipWords.any(folded.contains)) continue;
    final m = item.firstMatch(line);
    if (m == null) continue;
    final price = _num(m.group(2)!);
    final name = m.group(1)!.trim();
    if (price < 0 || foldText(name).startsWith('slev')) {
      // Sleva patří k předchozí položce.
      if (lines.isNotEmpty) {
        final next = lines.last.price - price.abs();
        if (next > 0) lines.last.price = (next * 100).round() / 100;
      }
      continue;
    }
    if (price == 0 || name.length < 2) continue;
    final pack = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(kg|g|ml|l|ks)\b',
      caseSensitive: false,
    ).firstMatch(name);
    lines.add(
      ReceiptLine(
        product: name,
        price: price,
        packQty: pack == null ? null : _num(pack.group(1)!),
        packUnit: pack?.group(2)!.toLowerCase() ?? '',
      ),
    );
  }
  return ParsedReceipt(
    lines: lines,
    storeId: guessReceiptStore(text),
    date: _date(text),
  );
}

/// Řádek elektronické účtenky „0.797 x 229.00 Kč“ (Albert, PDF z aplikace).
final _eReceiptLine = RegExp(
  r'(\d+(?:[.,]\d+)?)\s*x\s*(\d{1,6}[.,]\d{2})\s*Kč',
  caseSensitive: false,
);

/// Elektronická účtenka (PDF z aplikace obchodu): název na jednom řádku,
/// pod ním „množství x cena Kč  celkem Kč“, případně sleva „… -730.00 Kč“.
/// Vážené zboží (desetinné množství, „E“/„P“/„M“) má cenu za 1 kg.
/// Pořadí řádků se mezi čtečkami PDF liší, proto se značky DPH a vážení
/// i samostatné součty jen přeskakují.
ParsedReceipt parseEReceiptText(String text) {
  final lines = <ReceiptLine>[];
  final unitTotals = <ReceiptLine, double>{};
  final qtys = <ReceiptLine, double>{};
  String? name;
  var started = !RegExp(r'polo[zž]ka', caseSensitive: false).hasMatch(text);
  final amountOnly = RegExp(r'^-?\d{1,6}[.,]\d{2}\s*Kč$', caseSensitive: false);
  final discount = RegExp(
    r'^(.*?[A-Za-zÀ-ž].*?)\s*(-\d{1,6}[.,]\d{2})\s*Kč$',
    caseSensitive: false,
  );
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) continue;
    final folded = foldText(line);
    if (!started) {
      if (folded.startsWith('polozka')) started = true;
      continue;
    }
    if (folded.startsWith('celkem')) break;
    void applyDiscount(String amount) {
      if (lines.isEmpty) return;
      final last = lines.last;
      final total = unitTotals[last]! - _num(amount).abs();
      unitTotals[last] = total;
      if (total > 0) last.price = ((total / qtys[last]!) * 100).round() / 100;
    }

    // Značky DPH (A/B/C) a vážení (E/P/M), kredity.
    if (RegExp(r'^[A-Z]$').hasMatch(line)) continue;
    if (amountOnly.hasMatch(line)) {
      // Samostatný součet se přeskočí; záporná částka je sleva
      // (u některých čteček je popis slevy na zvláštním řádku).
      if (line.startsWith('-')) {
        applyDiscount(
          line.replaceAll(RegExp(r'\s*Kč$', caseSensitive: false), ''),
        );
        name = null;
      }
      continue;
    }
    if (folded.startsWith('ziskan') || folded.startsWith('kupon')) continue;
    final qty = _eReceiptLine.firstMatch(line);
    if (qty != null) {
      // Název může být i na stejném řádku („ROHLÍK43GR 8 x 3.50 Kč …“).
      final prefix = line
          .substring(0, qty.start)
          .trim()
          .replaceAll(RegExp(r'(\s+[A-Z]){1,2}$'), '')
          .trim();
      final itemName = RegExp(r'[A-Za-zÀ-ž]{2}').hasMatch(prefix)
          ? prefix
          : name;
      name = null;
      if (itemName == null || foldText(itemName).startsWith('zaokrouhl')) {
        continue;
      }
      final amount = _num(qty.group(1)!);
      final unit = _num(qty.group(2)!);
      if (amount <= 0 || unit <= 0) continue;
      final weighed =
          amount != amount.roundToDouble() ||
          RegExp(r'Kč\s*[EPM]\b').hasMatch(line) ||
          RegExp(
            r'\s[EPM](\s+[A-C])?\s*\d+(?:[.,]\d+)?\s*x',
            caseSensitive: true,
          ).hasMatch(line);
      final pack = weighed ? null : _packOf(itemName);
      final receipt = ReceiptLine(
        product: _titleCase(itemName),
        price: unit,
        packQty: weighed ? 1 : pack?.$1,
        packUnit: weighed ? 'kg' : pack?.$2 ?? '',
      );
      lines.add(receipt);
      unitTotals[receipt] = amount * unit;
      qtys[receipt] = amount;
      continue;
    }
    final disc = discount.firstMatch(line);
    if (disc != null) {
      applyDiscount(disc.group(2)!);
      name = null;
      continue;
    }
    if (RegExp(r'[A-Za-zÀ-ž]{2}').hasMatch(line) && !line.contains('Kč')) {
      // Název položky (u některých čteček se značkou „B“ / „E A“ na konci).
      name = line.replaceAll(RegExp(r'(\s+[A-Z]){1,2}$'), '').trim();
    }
  }
  lines.removeWhere((l) => l.price <= 0);
  return ParsedReceipt(
    lines: lines,
    storeId: guessReceiptStore(text),
    date: _date(text),
  );
}

(double, String)? _packOf(String name) {
  final m = RegExp(
    r'(\d+(?:[.,]\d+)?)\s*(kg|gr|g|ml|l|ks)(?![a-z])',
    caseSensitive: false,
  ).firstMatch(name);
  if (m == null) return null;
  final unit = m.group(2)!.toLowerCase();
  return (_num(m.group(1)!), unit == 'gr' ? 'g' : unit);
}

/// „KUŘECÍ PRSNÍ ŘÍZKY“ → „Kuřecí prsní řízky“ (účtenky píší velkými).
String _titleCase(String value) {
  if (value != value.toUpperCase()) return value;
  final lower = value.toLowerCase();
  return lower.isEmpty ? lower : lower[0].toUpperCase() + lower.substring(1);
}

/// Prodejna podle hlavičky účtenky (jen když je jednoznačná).
String? guessReceiptStore(String text) {
  final t = foldText(text);
  if (t.contains('tesco')) return 'tesco-hradecka';
  if (t.contains('penny')) return 'penny-nadrazni';
  if (t.contains('lidl')) return 'lidl-hradecka';
  if (t.contains('albert')) {
    if (t.contains('masaryk')) return 'albert-tgm';
    if (t.contains('hradeck')) return 'albert-hradecka';
    return null;
  }
  if (RegExp(r'\bjip\b').hasMatch(t)) return 'jip-hradecka';
  if (t.contains('coop') || t.contains('konzumni')) {
    if (t.contains('lerchov')) return 'coop-lerchova';
    if (t.contains('smetanov')) return 'coop-smetanova';
    if (t.contains('nadrazni')) return 'coop-nadrazni';
    if (t.contains('svobody')) return 'coop-namesti';
  }
  return null;
}

DateTime? _date(String text) {
  final m = RegExp(r'\b(\d{1,2})\.\s?(\d{1,2})\.\s?(\d{4})\b').firstMatch(text);
  if (m == null) return null;
  final d = DateTime.tryParse(
    '${m.group(3)}-${m.group(2)!.padLeft(2, '0')}-${m.group(1)!.padLeft(2, '0')}',
  );
  return d;
}

double _num(String s) => double.parse(s.replaceAll(',', '.'));
