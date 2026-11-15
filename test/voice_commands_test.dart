import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/voice_commands.dart';

void main() {
  test('české hlasové povely', () {
    expect(parseVoiceCommand('Další'), VoiceCommand.next);
    expect(parseVoiceCommand('další krok'), VoiceCommand.next);
    expect(parseVoiceCommand('hotovo'), VoiceCommand.next);
    expect(parseVoiceCommand('Zpět'), VoiceCommand.previous);
    expect(parseVoiceCommand('vrať se o krok'), VoiceCommand.previous);
    expect(parseVoiceCommand('přečti to znovu'), VoiceCommand.repeat);
    expect(parseVoiceCommand('opakuj'), VoiceCommand.repeat);
    expect(parseVoiceCommand('spusť časovač'), VoiceCommand.timer);
    expect(parseVoiceCommand('pauza'), VoiceCommand.pause);
    expect(parseVoiceCommand('pokračuj'), VoiceCommand.resume);
    expect(
      parseVoiceCommand('jaké suroviny potřebuju'),
      VoiceCommand.ingredients,
    );
    expect(parseVoiceCommand('dokončit vaření'), VoiceCommand.finish);
    expect(parseVoiceCommand('dobrý den'), isNull);
  });
}
