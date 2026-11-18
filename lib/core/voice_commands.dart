import 'kitchen_math.dart' show foldText;

/// Hlasové povely v režimu Vaříme spolu.
enum VoiceCommand {
  next,
  previous,
  repeat,
  timer,
  pause,
  resume,
  ingredients,
  finish,
}

/// Rozpozná povel z rozpoznané věty („další krok“, „vrať se“, „přečti to
/// znovu“, „spusť časovač“…). Vrací `null`, když věta není povel.
VoiceCommand? parseVoiceCommand(String words) {
  final text = ' ${foldText(words).replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')} ';
  bool has(List<String> stems) => stems.any((s) => text.contains(s));

  if (has([' dokonc', ' konec', ' hotovo vse', ' uz je hotovo', ' ukonc'])) {
    return VoiceCommand.finish;
  }
  if (has([' pokracuj', ' pokracovat', ' znovu spust', ' rozbeh'])) {
    return VoiceCommand.resume;
  }
  if (has([' pauz', ' pozastav', ' zastav', ' pockej']))
    return VoiceCommand.pause;
  if (has([' casovac', ' minutk', ' stopk', ' odpocitav', ' nastav cas'])) {
    return VoiceCommand.timer;
  }
  if (has([' surovin', ' co potrebuju', ' ingredienc'])) {
    return VoiceCommand.ingredients;
  }
  if (has([' zpet', ' predchozi', ' vrat', ' minuly']))
    return VoiceCommand.previous;
  if (has([' opakuj', ' precti', ' znovu', ' jeste jednou', ' cti'])) {
    return VoiceCommand.repeat;
  }
  if (has([' dalsi', ' dal ', ' pokracuj', ' hotovo', ' mam', ' jedem'])) {
    return VoiceCommand.next;
  }
  return null;
}
