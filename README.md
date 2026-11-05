# LCExtForward

Tweak für LiveContainer (Branch `bypass-mem-poc` oder neuer), mit dem eine Guest-App
ihre eigenen privaten App-Extensions starten kann, z. B. Madeiras `MadeiraMemoryHost`.
Die Extension läuft dann in einer Instanz von LiveContainers `LiveProcess.appex`
(Extension-Point `com.apple.ar.viewer`, ohne Jetsam-Speicherlimit).

## Ablauf

1. Guest-App ruft `+[NSExtension extensionWithIdentifier:]` mit der ID ihrer Appex auf.
2. Das System kennt die ID nicht. Der Tweak findet die Appex in `Guest.app/PlugIns/`
   und gibt stattdessen das `NSExtension`-Objekt von LiveProcess zurück.
3. Beim `beginExtensionRequest…` ergänzt der Tweak die `userInfo` des ersten Items um
   `customPayloadDylib` (sich selbst), `customPayloadEntry` und den Appex-Pfad. Die
   Schlüssel der Guest-App (bei Madeira `endpoint`) bleiben erhalten.
4. LiveProcess lädt den Tweak als Payload. `LCExtForwardMain` setzt die Appex als
   `mainBundle`, lädt ihre Binary, erzeugt die `NSExtensionPrincipalClass` und ruft
   `beginRequestWithExtensionContext:` mit dem echten Kontext auf.

Interruption-Block, `pidForRequestIdentifier:` und `_kill:` funktionieren normal, weil
die Guest-App ein echtes `NSExtension`-Objekt bekommt.

## Zwei Tweaks

| Datei | Ordner | Rolle |
|---|---|---|
| `LCExtForward.dylib` | **Per-App**-Tweak-Ordner (nur Apps, die es brauchen) | Guest-Hook + LiveProcess-Payload |
| `LCExtForwardHost.dylib` | **globaler** Tweak-Ordner | Import-Hook, ersetzt `patch_appex.py` (optional) |

`LCExtForward.dylib` gehört **nur** in den Per-App-Ordner, nicht zusätzlich in den globalen –
sonst lädt es mit „Tweaks selber laden" auch in den LC-Host, wo es nichts zu tun hat.

## Benutzung

1. LiveContainer muss mit **„Keep App Extensions“** installiert sein (sonst fehlt LiveProcess).
2. Appex als `dlopen`-bare `MH_DYLIB` vorbereiten – auf **einem** von zwei Wegen:
   - **Mit Host-Tweak** (empfohlen, kein Vorab-Schritt): siehe „Host-Tweak" unten. Dann entfällt 3.
   - **Ohne**: `python3 patch_appex.py Madeira.ipa Madeira-lc.ipa`
3. (nur ohne Host-Tweak) Gepatchte IPA in LiveContainer importieren.
4. `LCExtForward.dylib` in den **Per-App**-Tweak-Ordner legen, der App zuweisen, in LC signieren.

**Auch mit JIT** müssen Tweak und Appex mit dem Zertifikat von LiveContainer signiert sein:
JIT gilt nur für den Prozess der Guest-App, nicht für die LiveProcess-Instanz, die die
Extension ausführt. In LC also ein Zertifikat eingerichtet haben und bei der App
„Don't Sign“ ausschalten.

Der Guest-Ordner (LCs Documents) lässt LiveProcess die Dateien zwar lesen, aber nicht als
ausführbaren Code mappen (die Sandbox blockiert dort `mmap(PROT_EXEC)`). Die App-Group
erlaubt das. Der Tweak legt deshalb beim ersten Weiterleiten beides in der App-Group ab
(`LiveContainer/LCExtForward/`): sich selbst als Payload und die komplette `.appex`. Von
dort lädt LiveProcess beides. Bookmarks für die App und ihren Datencontainer gehen mit
(für das Log). Die Kopien werden erneuert, sobald sich Tweak oder Appex ändern.

Die LC-Signatur ist Teil jeder Mach-O-Datei und bleibt beim Kopieren erhalten. Appex und
Tweak müssen also vor dem Import in LC signiert worden sein.

**Log:** Standardmäßig **aus**. Die mitgelieferte Dylib schreibt also nichts und ruft kein
`NSLog`. Zum Debuggen mit `make LOG=1` neu bauen – dann schreiben beide Seiten nach
`LCExtForward.log` im Documents-Ordner des Datencontainers der App (Dateien-App →
LiveContainer → Data → Application → …).

Die beiliegende `LCExtForward.dylib` ist fertig gebaut: arm64, iOS 16+, clang 18 mit
`ld64.lld` und iOS-16.5-SDK, Chained Fixups, ad-hoc signiert. Selbst bauen geht auf dem
Mac mit `make`.

## Grenzen

- Nur Extensions, die die App selbst über `NSExtension` startet. Beide Varianten werden
  abgefangen: `…completion:` (z. B. Madeira) und `…error:` (z. B. Reynard/Gecko).
  Widgets, Share-, Keyboard- oder Notification-Extensions ruft iOS auf; die gehen nicht.
- Jede weitergeleitete Extension läuft als `com.apple.ar.viewer`, egal was sie deklariert.
- Storyboard-basierte Extensions (`NSExtensionMainStoryboard`) werden nicht unterstützt.
- Die Appex wird in die App-Group kopiert und läuft dadurch außerhalb des Guest-Bundles.
  Hängt eine Appex an Frameworks der Guest-App (`@rpath`), findet sie diese dort nicht.
  MadeiraMemoryHost ist eigenständig (nur Foundation/XPC/mach). Für Apps mit eigenen
  Frameworks (Reynard: `GeckoView.framework`/`XUL`) werden diese mit in die App-Group
  staviert – siehe Hinweis unten.
- Ungetestet auf einem Gerät (außer Madeira). Logs mit `make LOG=1` zeigen, wo es hängt.

## Apps mit eigenen Frameworks (Reynard u. ä.)

Apps wie Reynard laden im Helfer große eigene Frameworks (`GeckoView.framework`, `XUL`)
per `@rpath` relativ zum App-Bundle. Der Tweak staviert deshalb eine Mini-Bundle-Struktur
in die App-Group:

```
<AppGroup>/LiveContainer/LCExtForward/<App>/PlugIns/<Helper>.appex
<AppGroup>/LiveContainer/LCExtForward/<App>/Frameworks/   (XUL, GeckoView.framework, *.dylib)
```

Dadurch löst sich `@rpath/../../Frameworks` des Helfers neben der staviert Appex auf, und
die Frameworks liegen in der App-Group, wo LiveProcess sie ausführbar mappen darf. Die
Frameworks werden **einmal** kopiert (idempotent per mtime) – der erste Kindprozess-Start
zahlt den Kopier-Aufwand, die weiteren nutzen die Kopie. Bei App-Update/Neu-Signieren
ändert sich die mtime und es wird neu kopiert.

Falls das pro App zu viel Platz kostet, wäre die Alternative, in place aus dem echten
Bundle über `LCBootstrap`s Loader zu laden – das bleibt der aufwändigere Weg in Reserve.

## Host-Tweak (ohne patch_appex.py)

`LCExtForwardHost.dylib` macht `patch_appex.py` überflüssig: es hookt im LC-**Host** den
Signier-Schritt (`+[LCUtils signAppBundleWithZSign:]`) und wandelt jede `PlugIns/*.appex`
einer freigeschalteten App in eine `MH_DYLIB` um, **bevor** LC mit ZSign signiert (dieselbe
Umwandlung wie `patch_appex.py`, gegengetestet byte-identisch). ZSign signiert das Bundle
rekursiv, die Appex also gleich mit.

Einrichten:
1. `LCExtForwardHost.dylib` **und** `LCExtForward.apps` in den **globalen** Tweak-Ordner legen.
2. In LC signieren lassen (wie jeden Tweak).
3. Settings → Developer → **„Tweaks selber in LiveContainer laden"** einschalten, LC neu starten.
4. In `LCExtForward.apps` die Apps eintragen (`.app`-Name oder Bundle-ID, `*` = alle),
   dann die App in LC einmal **neu signieren**.

**Sicher per Default / Opt-in:** Der Host-Tweak macht nichts, solange eine App nicht in
`LCExtForward.apps` steht. Apps **ohne** Extensions sind nie betroffen (keine `.appex` zum
Umwandeln). Läuft er versehentlich in einem Guest statt im Host, ist er ebenfalls wirkungslos
(er prüft auf `LCUtils`). Bei jeder Unstimmigkeit signiert er das Bundle unverändert.
