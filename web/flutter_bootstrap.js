{{flutter_js}}
{{flutter_build_config}}

// Bez Flutter service workeru (je zastaralý a sám se odregistruje). Místo něj
// běží push_sw.js, který jen zobrazuje oznámení od rodiny – nic neukládá
// do mezipaměti a nemění načítání aplikace.
_flutter.loader.load();
