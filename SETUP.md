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

## Files (arm64, iOS 16+)

| File | Purpose |
|---|---|
| `LCExtForward.dylib` | The tweak – converts appexes while signing, forwards extensions, runs them in LiveProcess |
| `LCExtForward-log.dylib` | Same as above, with logging (for troubleshooting) |
| `LCExtForward.apps` | Opt-in list: which apps the tweak handles |

---

## A) Install the tweak (once)

1. Put `LCExtForward.dylib` **and** `LCExtForward.apps` into the **global** tweak folder,
   both directly in the folder (no subfolder):
   Files app → "On My iPhone" → **LiveContainer → `Tweaks/`**
   (with shared bundle/SideStore: app group → `LiveContainer/Tweaks/`).
2. Let LiveContainer **sign** the tweaks (tweak manager).
3. **Settings → Developer → enable "Load Tweaks to Self"**
   (`LCLoadTweaksToSelf`; German UI: „Tweaks selber in LiveContainer laden").
4. **Fully restart** LiveContainer (close it from the app switcher and reopen it).

## B) Add an app

5. Add the app to `LCExtForward.apps` – one app per line, as **bundle ID** or **`.app` name**:
   ```
   com.willfaust.madeora.app
   com.minh-ton.Reynard
   ```
   `*` on a line = all apps. Empty file = nothing is touched.
6. **Import** the IPA into LiveContainer as usual (no `patch_appex.py` needed), if not done yet.
7. **Re-sign** the app in LiveContainer **once**. The tweak converts its appex(es) during this step.
8. Launch the app.
    - **Gecko apps (Reynard):** the **first launch takes longer** – the frameworks
      (XUL/GeckoView, a few hundred MB) are copied into the app group once.
      Later launches are fast.

> Apps without extensions, or apps not on the list, are **not** modified, and the tweak does
> nothing in them.

## Order – important

Add the app to `LCExtForward.apps` **→ then** sign the app. The conversion happens while
signing; if the app is not on the list beforehand, nothing is converted and the
extension will not start. Re-sign the app after adding it to the list.

## Upgrading from 1.x

1.x had two dylibs. Remove both before installing 2.x:
- `LCExtForwardHost.dylib` from the global tweak folder,
- `LCExtForward.dylib` from every per-app tweak folder (and unassign those folders).

Then follow part A. Apps that were already converted do not need to be re-signed.

---

## Troubleshooting

If something goes wrong, put the **logging variant** `LCExtForward-log.dylib` into the global
tweak folder instead of `LCExtForward.dylib` (sign it, restart LiveContainer) and try again.
It writes `LCExtForward.log` to the Documents folder of each data container:

- **Conversion while signing:** Files → LiveContainer → `LCExtForward.log` (LiveContainer's own Documents).
- **Forwarding in the app:** Files → LiveContainer → **Data → Application → (the app's container) → `Documents/LCExtForward.log`**.

Typical lines:
- `host role: converting appexes …` → the tweak is loaded into LiveContainer itself.
- `converted ….appex/…` → an appex was converted while signing.
- `not listed in LCExtForward.apps, forwarding disabled` → add the app to the list.
- `forwarding … to … LiveProcess` → forwarding works.
- `staged Frameworks (…)` → frameworks were copied (Gecko apps only).
- `running com.…Helper …` → the extension is running.
- `dlopen … failed: … @rpath/…` → a library is missing (frameworks not copied/signed).
- `dlopen … sandbox blocked mmap()` → the appex was not converted (check "Load Tweaks to Self",
  the opt-in list, then re-sign the app).

## Building it yourself (macOS + Xcode)

```
make           # silent
make LOG=1     # with logging
```
