import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/providers.dart';

void main() {
  test('chyba při obnově dat se zobrazí a další změna se načte', () async {
    final changes = StreamController<void>.broadcast();
    final states = StreamController<AsyncValue<int>>();
    final reads = StreamIterator(states.stream);
    final readError = StateError('Chyba čtení místní databáze');
    var count = 0;
    final provider = StreamProvider<int>(
      (ref) => watchRepositoryData(
        ref,
        Future.value(changes),
        (repository) => repository.stream,
        (repository) async {
          count++;
          if (count == 2) throw readError;
          return count;
        },
      ),
      retry: (retryCount, error) => null,
    );
    final container = ProviderContainer();
    addTearDown(() async {
      container.dispose();
      await reads.cancel();
      await states.close();
      await changes.close();
    });
    container.listen(provider, (_, current) => states.add(current));

    expect(await reads.moveNext(), isTrue);
    expect(reads.current.value, 1);

    changes.add(null);
    expect(await reads.moveNext(), isTrue);
    expect(reads.current.error, same(readError));

    changes.add(null);
    expect(await reads.moveNext(), isTrue);
    expect(reads.current.value, 3);
  });
}
