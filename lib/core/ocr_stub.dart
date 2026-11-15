/// Ve webové verzi čtení textu z fotky není.
bool get ocrAvailable => false;

Future<String> readTextFromImage(String path) =>
    throw UnsupportedError('Čtení textu z fotky je jen v aplikaci v telefonu.');
