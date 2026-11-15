# Čtení textu z fotky (ML Kit) – aplikace používá jen latinku; ostatní
# písma (čínština, japonština, korejština, dévanágarí) nejsou přibalená.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit si své vnitřní části (registr komponent, továrny rozpoznávače) hledá
# za běhu podle názvů tříd. R8 v release sestavení tyto třídy přejmenoval nebo
# odstranil, registr pak vrátil null a vytvoření rozpoznávače textu spadlo
# s NullPointerException („getClass() on a null object reference“).
# Ověřeno na emulátoru: profile sestavení (bez R8) text přečte, release ne.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
