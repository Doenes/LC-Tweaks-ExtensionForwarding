# LCExtForward – Einrichtung (Schritt für Schritt)

**Zweck:** Guest-Apps in LiveContainer können ihre eigenen privaten App-Extensions
starten, die im Container sonst fehlen – z. B. Madeiras Memory-Host oder Reynards
Gecko-Kindprozesse. Die Extension läuft dann in LiveContainers `LiveProcess.appex`.

Gilt nur für Extensions, die die App **selbst** über `NSExtension` startet (Helfer-
Prozesse). Widgets, Share-/Keyboard-/Notification-Extensions gehen nicht (die startet iOS).

---

## Voraussetzungen

- **LiveContainer mit „Keep App Extensions" sideloadet.** Bei SideStore beim Installieren
  „Keep App Extensions (Use Main Profile)" wählen. Nur so existiert `LiveProcess.appex`.
- In LiveContainer ist ein **Signatur-Zertifikat eingerichtet**. Bei jeder betroffenen App
  muss **„Don't Sign" AUS** sein (sie muss mit dem Zertifikat signiert werden – gilt auch mit JIT,
  weil die Extension in einem separaten, JIT-losen Prozess läuft).

## Dateien (alle arm64, iOS 16+)

| Datei | Zweck |
|---|---|
| `LCExtForward.dylib` | Per-App-Tweak: Hook in der App + Payload in LiveProcess |
| `LCExtForwardHost.dylib` | Host-Tweak: wandelt Appexes beim Signieren um (ersetzt `patch_appex.py`) |
| `LCExtForward.apps` | Opt-in-Liste: welche Apps der Host-Tweak behandelt |

---

## A) Host-Tweak einrichten (einmalig)

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
   `*` in einer Zeile = alle Apps. Leere Datei = nichts wird angefasst.

> Apps ohne Extensions oder Apps, die nicht in der Liste stehen, werden **nicht** verändert.

## B) Pro App einrichten (die weitergeleitet werden soll)

6. Die App muss in `LCExtForward.apps` stehen (Schritt 5) – **vor** dem Signieren.
7. IPA ganz normal in LiveContainer **importieren** (kein `patch_appex.py` nötig).
8. `LCExtForward.dylib` in einen **per-App-Tweak-Ordner** legen und **genau dieser App zuweisen**,
   dann in LiveContainer signieren.
   → **Nicht** in den globalen Ordner legen – der ist nur für den Host-Tweak.
9. Die App in LiveContainer **einmal neu signieren**. Dabei wandelt der Host-Tweak ihre
   Appex(es) um.
10. App starten.
    - **Gecko-Apps (Reynard):** Der **erste Start dauert länger** – die Frameworks
      (XUL/GeckoView, einige hundert MB) werden einmalig in die App-Group kopiert.
      Spätere Starts sind schnell.

## Reihenfolge – wichtig

`LCExtForward.apps` eintragen **→ dann** die App signieren. Die Umwandlung passiert beim
Signieren; steht die App vorher nicht in der Liste, wird nichts umgewandelt und die
Extension startet nicht.

---

## Fehlersuche

Gibt es Probleme, die **Log-Variante** von `LCExtForward.dylib` statt der stillen einsetzen
(`make LOG=1`, oder die separat gelieferte `LCExtForward-log.dylib`) und die App einmal starten.
Sie schreibt `LCExtForward.log` in den Documents-Ordner des App-Datencontainers:
Dateien → LiveContainer → **Data → Application → (Container der App) → `Documents/LCExtForward.log`**.

Typische Zeilen:
- `forwarding … to … LiveProcess` → Weiterleitung läuft.
- `staged Frameworks (…)` → Frameworks wurden kopiert (nur Gecko-Apps).
- `running com.…Helper …` → Extension läuft.
- `dlopen … failed: … @rpath/…` → eine Bibliothek fehlt (Frameworks nicht mitkopiert/signiert).
- `dlopen … sandbox blocked mmap()` → Appex wurde nicht umgewandelt (Host-Tweak/Opt-in prüfen).

## Selbst bauen (macOS + Xcode)

```
make           # beide Dylibs, still
make LOG=1     # per-App-Tweak mit Logging
```
