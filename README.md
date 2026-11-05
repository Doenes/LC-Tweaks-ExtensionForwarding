# LCExtForward

Tweak für [LiveContainer](https://github.com/LiveContainer/LiveContainer), mit dem Guest-Apps
ihre **eigenen privaten App-Extensions** starten können, die im Container sonst fehlen –
z. B. Madeiras Memory-Host oder Reynards Gecko-Kindprozesse. Die Extension läuft dann in
LiveContainers `LiveProcess.appex`.

> Gilt nur für Extensions, die die App **selbst** über `NSExtension` startet (Helfer-Prozesse).
> Widgets, Share-, Keyboard- und Notification-Extensions gehen nicht – die startet iOS.

## Download

Die fertigen Tweaks gibt es unter **[Releases](../../releases/latest)** (arm64, iOS 16+):

| Datei | Zweck |
|---|---|
| `LCExtForward.dylib` | Per-App-Tweak: Hook in der App + Payload in LiveProcess |
| `LCExtForward-log.dylib` | Wie oben, mit Logging (nur zur Fehlersuche) |
| `LCExtForwardHost.dylib` | Host-Tweak: wandelt Appexes beim Signieren um |
| `LCExtForward.apps` | Opt-in-Liste: welche Apps der Host-Tweak behandelt |
| `LCExtForward.zip` | Alles zusammen |

---

## Einrichtung

### Voraussetzungen

- **LiveContainer mit „Keep App Extensions" sideloaden** (Branch `bypass-mem-poc` oder neuer).
  Bei SideStore beim Installieren „Keep App Extensions (Use Main Profile)" wählen.
  Nur so existiert `LiveProcess.appex`.
- In LiveContainer ist ein **Signatur-Zertifikat eingerichtet**. Bei jeder betroffenen App
  muss **„Don't Sign" AUS** sein. Das gilt **auch mit JIT**, weil die Extension in einem
  separaten, JIT-losen Prozess läuft.

### A) Host-Tweak einrichten (einmalig)

1. `LCExtForwardHost.dylib` **und** `LCExtForward.apps` in den **globalen** Tweak-Ordner legen,
   beide direkt im Ordner (kein Unterordner):
   Dateien-App → „Auf meinem iPhone" → **LiveContainer → `Tweaks/`**
   (bei Shared-Bundle/SideStore: App-Group → `LiveContainer/Tweaks/`).
2. In LiveContainer die Tweaks **signieren** lassen (Tweak-Verwaltung).
3. **Settings → Developer → „Tweaks selber in LiveContainer laden" einschalten.**
4. LiveContainer **komplett neu starten** (aus dem App-Switcher schließen und neu öffnen).
5. `LCExtForward.apps` bearbeiten – pro Zeile eine App, als **Bundle-ID** oder **`.app`-Name**:
   ```
   com.willfaust.madeora.app
   com.minh-ton.Reynard
   ```
   `*` = alle Apps, `#` = Kommentar. Leere Datei = nichts wird angefasst.

> Apps ohne Extensions oder Apps, die nicht in der Liste stehen, werden **nicht** verändert.

### B) Pro App einrichten

6. Die App muss in `LCExtForward.apps` stehen (Schritt 5) – **vor** dem Signieren.
7. IPA ganz normal in LiveContainer **importieren**.
8. `LCExtForward.dylib` in einen **per-App-Tweak-Ordner** legen, **genau dieser App zuweisen**
   und in LiveContainer signieren.
   → **Nicht** in den globalen Ordner legen – sonst lädt es auch in den LC-Host, wo es nichts tut.
9. Die App in LiveContainer **einmal neu signieren**. Dabei wandelt der Host-Tweak ihre
   Appex(es) um.
10. App starten.
    - **Gecko-Apps (Reynard):** Der **erste Start dauert länger** – die Frameworks
      (XUL/GeckoView, einige hundert MB) werden einmalig in die App-Group kopiert.
      Spätere Starts sind schnell.

> **Reihenfolge ist wichtig:** erst `LCExtForward.apps` eintragen, **dann** die App signieren.
> Die Umwandlung passiert beim Signieren – steht die App vorher nicht in der Liste, wird nichts
> umgewandelt und die Extension startet nicht. Nach jeder Änderung an der Liste die App neu signieren.

---

## Fehlersuche

Statt `LCExtForward.dylib` die **`LCExtForward-log.dylib`** als per-App-Tweak einsetzen
(signieren nicht vergessen) und die App einmal starten. Das Log landet im Documents-Ordner
des App-Datencontainers:
Dateien → LiveContainer → **Data → Application → (Container der App) → `Documents/LCExtForward.log`**.

| Log-Zeile | Bedeutung |
|---|---|
| `forwarding … to … LiveProcess` | Weiterleitung läuft |
| `staged Frameworks (…)` | Frameworks wurden kopiert (nur Gecko-Apps) |
| `running com.…Helper …` | Extension läuft |
| `dlopen … failed: … @rpath/…` | Eine Bibliothek fehlt (Frameworks nicht mitkopiert/signiert) |
| `dlopen … sandbox blocked mmap()` | Appex wurde nicht umgewandelt → Host-Tweak/Opt-in-Liste prüfen |

## Grenzen

- Nur Extensions, die die App selbst über `NSExtension` startet. Beide Varianten werden
  abgefangen: `…completion:` (z. B. Madeira) und `…error:` (z. B. Reynard/Gecko).
- Jede weitergeleitete Extension läuft als `com.apple.ar.viewer` (ohne Jetsam-Speicherlimit),
  egal was sie deklariert.
- Storyboard-basierte Extensions (`NSExtensionMainStoryboard`) werden nicht unterstützt.
- Getestet auf einem Gerät bisher nur mit Madeira.

---

## Technische Details

### Ablauf

1. Die Guest-App ruft `+[NSExtension extensionWithIdentifier:]` mit der ID ihrer Appex auf.
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

### Warum die App-Group?

LiveProcess darf Dateien im Guest-Ordner (LCs Documents) zwar lesen, aber nicht als
ausführbaren Code mappen – die Sandbox blockiert dort `mmap(PROT_EXEC)`. In der App-Group
ist das erlaubt. Der Tweak legt deshalb beim ersten Weiterleiten sich selbst und die
komplette `.appex` unter `LiveContainer/LCExtForward/` ab; von dort lädt LiveProcess beides.
Bookmarks für die App und ihren Datencontainer gehen mit (für das Log). Die Kopien werden
erneuert, sobald sich Tweak oder Appex ändern.

Die LC-Signatur ist Teil jeder Mach-O-Datei und bleibt beim Kopieren erhalten – deshalb
müssen Appex und Tweak vorher in LC signiert worden sein.

### Apps mit eigenen Frameworks (Reynard u. ä.)

Helfer wie Reynards Gecko-Prozess laden große Frameworks (`GeckoView.framework`, `XUL`)
per `@rpath` relativ zum App-Bundle. Der Tweak legt deshalb eine Mini-Bundle-Struktur in
der App-Group an:

```
<AppGroup>/LiveContainer/LCExtForward/<App>/PlugIns/<Helper>.appex
<AppGroup>/LiveContainer/LCExtForward/<App>/Frameworks/   (XUL, GeckoView.framework, *.dylib)
```

So löst sich `@rpath/../../Frameworks` des Helfers neben der kopierten Appex auf. Die
Frameworks werden nur einmal kopiert (Abgleich per mtime); nach App-Update oder
Neu-Signieren wird neu kopiert.

### Host-Tweak

`LCExtForwardHost.dylib` hookt im LC-**Host** den Signier-Schritt
(`+[LCUtils signAppBundleWithZSign:]`) und wandelt jede `PlugIns/*.appex` einer
freigeschalteten App in eine `dlopen`-bare `MH_DYLIB` um, **bevor** ZSign das Bundle
rekursiv signiert.

Sicher per Default: Er tut nichts, solange eine App nicht in `LCExtForward.apps` steht.
Apps ohne Extensions sind nie betroffen. Läuft er versehentlich in einem Guest statt im
Host, ist er wirkungslos (Prüfung auf `LCUtils`). Bei jeder Unstimmigkeit signiert er das
Bundle unverändert.

### Alternative ohne Host-Tweak: `patch_appex.py`

Dieselbe Umwandlung (byte-identisch) geht auch vorab am Rechner:

```
python3 patch_appex.py Madeira.ipa Madeira-lc.ipa
```

Die gepatchte IPA dann in LiveContainer importieren und nur Teil **B** (ohne Schritt 6 und 9)
befolgen.

## Selbst bauen

Auf macOS mit Xcode:

```
make           # beide Dylibs, ohne Logging
make LOG=1     # per-App-Tweak mit Logging
```

Releases baut GitHub Actions automatisch (`.github/workflows/release.yml`): unter
**Actions → Release → Run workflow** eine neue Versionsnummer (z. B. `v1.0.1`) angeben.
