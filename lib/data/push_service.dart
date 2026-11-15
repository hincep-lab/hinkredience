import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/web_push.dart';

/// Oznámení do zavřené aplikace přes serverovou funkci `push`.
class PushService {
  PushService(this._client);

  final SupabaseClient _client;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final response = await _client.functions.invoke('push', body: body);
    final data = response.data;
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// Zapne oznámení na tomto zařízení (prohlížeč / aplikace z plochy).
  Future<void> enableThisDevice() async {
    final key = (await _call({'action': 'key'}))['publicKey'];
    if (key is! String || key.isEmpty) {
      throw StateError('Server oznámení zatím nemá klíč.');
    }
    final sub = await webPushSubscribe(key);
    await _client.rpc<dynamic>(
      'push_subscribe',
      params: {
        'p_endpoint': sub.endpoint,
        'p_p256dh': sub.p256dh,
        'p_auth': sub.auth,
        'p_user_agent': 'web',
      },
    );
  }

  Future<void> disableThisDevice() async {
    final endpoint = await webPushUnsubscribe();
    if (endpoint.isEmpty) return;
    await _client.from('push_subscriptions').delete().eq('endpoint', endpoint);
  }

  /// Pošle zkušební oznámení na vlastní zařízení. Vrací počet doručených.
  Future<int> test() async {
    final data = await _call({'action': 'test'});
    return (data['sent'] as num?)?.toInt() ?? 0;
  }

  /// Dá vědět zbytku rodiny (chyby se jen zalogují – oznámení nesmí
  /// zastavit synchronizaci).
  Future<void> announce(List<Map<String, String>> items) async {
    if (items.isEmpty) return;
    await _call({'action': 'notify', 'items': items});
  }
}
