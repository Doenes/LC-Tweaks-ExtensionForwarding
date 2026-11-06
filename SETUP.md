# LCExtForward – Setup (step by step)

**Purpose:** Guest apps in LiveContainer can start their own private app extensions,
which are otherwise missing inside the container – e.g. Madeira's memory host or Reynard's
Gecko child processes. The extension then runs inside LiveContainer's `LiveProcess.appex`.

Only for extensions the app starts **itself** via `NSExtension` (helper processes).
Widgets, share, keyboard and notification extensions do not work (iOS launches those).

---

## Requirements

- **LiveContainer sideloaded with "Keep App Extensions".** With SideStore, choose
  "Keep App Extensions (Use Main Profile)" when installing. Only then does `LiveProcess.appex` exist.
- A **signing certificate is set up** in LiveContainer. For every affected app,
  **"Don't Sign" must be OFF** (it must be signed with the certificate – this applies even with JIT,
  because the extension runs in a separate process without JIT).

## Files (all arm64, iOS 16+)

| File | Purpose |
|---|---|
| `LCExtForward.dylib` | Per-app tweak: hook in the app + payload in LiveProcess |
| `LCExtForward-log.dylib` | Same as above, with logging (for troubleshooting) |
| `LCExtForwardHost.dylib` | Host tweak: converts appexes while signing (replaces `patch_appex.py`) |
| `LCExtForward.apps` | Opt-in list: which apps the host tweak handles |

---

## A) Set up the host tweak (once)

1. Put `LCExtForwardHost.dylib` **and** `LCExtForward.apps` into the **global** tweak folder,
   both directly in the folder (no subfolder):
   Files app → "On My iPhone" → **LiveContainer → `Tweaks/`**
   (with shared bundle/SideStore: app group → `LiveContainer/Tweaks/`).
2. Let LiveContainer **sign** the tweaks (tweak manager).
3. **Settings → Developer → enable "Load Tweaks to Self"**
   (`LCLoadTweaksToSelf`; German UI: „Tweaks selber in LiveContainer laden").
4. **Fully restart** LiveContainer (close it from the app switcher and reopen it).
5. Edit `LCExtForward.apps` – one app per line, as **bundle ID** or **`.app` name**:
   ```
   com.willfaust.madeora.app
   com.minh-ton.Reynard
   ```
   `*` on a line = all apps. Empty file = nothing is touched.

> Apps without extensions, or apps not on the list, are **not** modified.

## B) Set up each app (the one to be forwarded)

6. The app must be listed in `LCExtForward.apps` (step 5) – **before** signing.
7. **Import** the IPA into LiveContainer as usual (no `patch_appex.py` needed).
8. Put `LCExtForward.dylib` into a **per-app tweak folder** and **assign it to exactly this app**,
   then sign it in LiveContainer.
   → Do **not** put it into the global folder – that one is only for the host tweak.
9. **Re-sign** the app in LiveContainer **once**. The host tweak converts its appex(es)
   during this step.
10. Launch the app.
    - **Gecko apps (Reynard):** the **first launch takes longer** – the frameworks
      (XUL/GeckoView, a few hundred MB) are copied into the app group once.
      Later launches are fast.

## Order – important

Add the app to `LCExtForward.apps` **→ then** sign the app. The conversion happens while
signing; if the app is not on the list beforehand, nothing is converted and the
extension will not start.

---

## Troubleshooting

If something goes wrong, use the **logging variant** `LCExtForward-log.dylib` instead of the
silent one (or build it with `make LOG=1`) and launch the app once.
It writes `LCExtForward.log` to the Documents folder of the app's data container:
Files → LiveContainer → **Data → Application → (the app's container) → `Documents/LCExtForward.log`**.

Typical lines:
- `forwarding … to … LiveProcess` → forwarding works.
- `staged Frameworks (…)` → frameworks were copied (Gecko apps only).
- `running com.…Helper …` → the extension is running.
- `dlopen … failed: … @rpath/…` → a library is missing (frameworks not copied/signed).
- `dlopen … sandbox blocked mmap()` → the appex was not converted (check the host tweak/opt-in list).

## Building it yourself (macOS + Xcode)

```
make           # both dylibs, silent
make LOG=1     # per-app tweak with logging
```
