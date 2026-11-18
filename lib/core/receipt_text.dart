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

/// Text účtenky (z fotky) → položky s cenou, obchod a datum. Nic se
/// nedomýšlí: řádek bez čitelné ceny se vynechá.
ParsedReceipt parseReceiptText(String text) {
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
