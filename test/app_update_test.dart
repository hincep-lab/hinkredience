import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/app_update.dart';

void main() {
  test('nová verze se nabídne jen když je novější', () {
    const body = '{"build": 45, "apk": "hinkredience.apk"}';
    final update = parseAppUpdate(body, current: 39)!;
    expect(update.build, 45);
    expect(update.apkUrl, '${updateBaseUrl}hinkredience.apk');
    expect(parseAppUpdate(body, current: 45), isNull);
    expect(parseAppUpdate(body, current: 50), isNull);
  });

  test('vadná nebo cizí odpověď se ignoruje', () {
    expect(parseAppUpdate('nesmysl', current: 1), isNull);
    expect(parseAppUpdate('{"build": 99}', current: 1), isNull);
    expect(
      parseAppUpdate(
        '{"build": 99, "apk": "https://zlo.example/x.apk"}',
        current: 1,
      ),
      isNull,
      reason: 'stahovat jen z vlastní adresy',
    );
  });
}
