import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/app/providers.dart';
import 'package:hinkredience/data/sync_service.dart';

void main() {
  test('stav synchronizace pro ukazatel', () {
    expect(const SyncState().phaseFor(enabled: false), SyncPhase.localOnly);
    expect(const SyncState().phaseFor(enabled: true), SyncPhase.synced);
    expect(
      const SyncState(pending: 2).phaseFor(enabled: true),
      SyncPhase.pending,
    );
    expect(
      const SyncState(
        offline: true,
        errors: ['x'],
        pending: 2,
      ).phaseFor(enabled: true),
      SyncPhase.offline,
    );
    expect(
      const SyncState(errors: ['x']).phaseFor(enabled: true),
      SyncPhase.error,
    );
    expect(
      const SyncState(conflicts: 1, errors: ['x']).phaseFor(enabled: true),
      SyncPhase.conflict,
    );
    expect(
      const SyncState(running: true, conflicts: 1).phaseFor(enabled: true),
      SyncPhase.syncing,
    );
  });

  test('opakování po chybě s rostoucí prodlevou, nejvýše 5 minut', () {
    for (var i = 1; i < syncRetryDelays.length; i++) {
      expect(syncRetryDelays[i] > syncRetryDelays[i - 1], isTrue);
    }
    expect(syncRetryDelays.last, const Duration(minutes: 5));
  });

  test('rozpoznání výpadku připojení', () {
    expect(
      isOfflineError(Exception('SocketException: Failed host lookup')),
      isTrue,
    );
    expect(
      isOfflineError(Exception('ClientException with SocketException')),
      isTrue,
    );
    expect(
      isOfflineError(Exception('permission denied for table recipes')),
      isFalse,
    );
  });
}
