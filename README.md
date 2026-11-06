# LCExtForward

A tweak for [LiveContainer](https://github.com/LiveContainer/LiveContainer) that lets guest apps
start their **own private app extensions**, which are otherwise missing inside the container –
e.g. Madeira's memory host or Reynard's Gecko child processes. The extension then runs inside
LiveContainer's `LiveProcess.appex`.

> This only works for extensions the app starts **itself** via `NSExtension` (helper processes).
> Widgets, share, keyboard and notification extensions do not work – those are launched by iOS.

## Download

Prebuilt tweaks are available under **[Releases](../../releases/latest)** (arm64, iOS 16+):

| File | Purpose |
|---|---|
| `LCExtForward.dylib` | Per-app tweak: hook in the app + payload in LiveProcess |
| `LCExtForward-log.dylib` | Same as above, with logging (for troubleshooting only) |
| `LCExtForwardHost.dylib` | Host tweak: converts appexes while signing |
| `LCExtForward.apps` | Opt-in list: which apps the host tweak handles |
| `LCExtForward.zip` | Everything in one archive |

---

## Setup

### Requirements

- **Sideload LiveContainer with "Keep App Extensions"** (branch `bypass-mem-poc` or newer).
  With SideStore, choose "Keep App Extensions (Use Main Profile)" when installing.
  Only then does `LiveProcess.appex` exist.
- A **signing certificate is set up** in LiveContainer. For every affected app,
  **"Don't Sign" must be OFF**. This applies **even with JIT**, because the extension runs
  in a separate process without JIT.

### A) Set up the host tweak (once)

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
   `*` = all apps, `#` = comment. Empty file = nothing is touched.

> Apps without extensions, or apps not on the list, are **never** modified.

### B) Set up each app

6. The app must be listed in `LCExtForward.apps` (step 5) – **before** signing.
7. **Import** the IPA into LiveContainer as usual.
8. Put `LCExtForward.dylib` into a **per-app tweak folder**, **assign it to exactly this app**
   and sign it in LiveContainer.
   → Do **not** put it into the global folder – it would also load into the LC host, where it does nothing.
9. **Re-sign** the app in LiveContainer **once**. The host tweak converts its appex(es) during this step.
10. Launch the app.
    - **Gecko apps (Reynard):** the **first launch takes longer** – the frameworks
      (XUL/GeckoView, a few hundred MB) are copied into the app group once.
      Later launches are fast.

> **Order matters:** add the app to `LCExtForward.apps` **first**, **then** sign the app.
> The conversion happens while signing – if the app is not on the list at that point, nothing is
> converted and the extension will not start. Re-sign the app after every change to the list.

---

## Troubleshooting

Use **`LCExtForward-log.dylib`** as the per-app tweak instead of `LCExtForward.dylib`
(don't forget to sign it) and launch the app once. The log is written to the Documents folder
of the app's data container:
Files → LiveContainer → **Data → Application → (the app's container) → `Documents/LCExtForward.log`**.

| Log line | Meaning |
|---|---|
| `forwarding … to … LiveProcess` | Forwarding works |
| `staged Frameworks (…)` | Frameworks were copied (Gecko apps only) |
| `running com.…Helper …` | The extension is running |
| `dlopen … failed: … @rpath/…` | A library is missing (frameworks not copied/signed) |
| `dlopen … sandbox blocked mmap()` | The appex was not converted → check the host tweak and the opt-in list |

## Limitations

- Only extensions the app starts itself via `NSExtension`. Both variants are intercepted:
  `…completion:` (e.g. Madeira) and `…error:` (e.g. Reynard/Gecko).
- Every forwarded extension runs as `com.apple.ar.viewer` (without the Jetsam memory limit),
  regardless of what it declares.
- Storyboard-based extensions (`NSExtensionMainStoryboard`) are not supported.
- So far only tested on a device with Madeira.

---

## Technical details

### How it works

1. The guest app calls `+[NSExtension extensionWithIdentifier:]` with the ID of its appex.
2. The system does not know that ID. The tweak finds the appex in `Guest.app/PlugIns/`
   and returns LiveProcess's `NSExtension` object instead.
3. On `beginExtensionRequest…`, the tweak adds `customPayloadDylib` (itself),
   `customPayloadEntry` and the appex path to the `userInfo` of the first item. The guest
   app's own keys (Madeira's `endpoint`) are kept.
4. LiveProcess loads the tweak as its payload. `LCExtForwardMain` makes the appex the
   `mainBundle`, loads its binary, creates the `NSExtensionPrincipalClass` and calls
   `beginRequestWithExtensionContext:` with the real context.

The interruption block, `pidForRequestIdentifier:` and `_kill:` work normally, because
the guest app gets a real `NSExtension` object.

### Why the app group?

LiveProcess may read files in the guest folder (LC's Documents), but not map them as
executable code – the sandbox blocks `mmap(PROT_EXEC)` there. The app group allows it.
So on the first forward, the tweak copies itself and the complete `.appex` to
`LiveContainer/LCExtForward/` in the app group, and LiveProcess loads both from there.
Bookmarks for the app and its data container are passed along (for the log). The copies
are refreshed whenever the tweak or the appex changes.

The LC signature is part of every Mach-O file and survives copying – which is why the
appex and the tweak must have been signed by LC beforehand.

Staging is serialized (Gecko apps start several child processes at once) and goes through
a `.partial` copy plus rename, so an interrupted copy never leaves a half-written bundle behind.

### Apps with their own frameworks (Reynard etc.)

Helpers like Reynard's Gecko process load large frameworks (`GeckoView.framework`, `XUL`)
via `@rpath` relative to the app bundle. The tweak therefore creates a mini bundle layout
in the app group:

```
<AppGroup>/LiveContainer/LCExtForward/<App>/PlugIns/<Helper>.appex
<AppGroup>/LiveContainer/LCExtForward/<App>/Frameworks/   (XUL, GeckoView.framework, *.dylib)
```

This way the helper's `@rpath/../../Frameworks` resolves next to the copied appex. The
frameworks are copied only once; a fingerprint (size + mtime of each framework binary)
triggers a new copy after an app update or re-sign.

### Host tweak

`LCExtForwardHost.dylib` hooks the signing step in the LC **host**
(`+[LCUtils signAppBundleWithZSign:]`) and converts every `PlugIns/*.appex` of an opted-in
app into a `dlopen`-able `MH_DYLIB` **before** ZSign signs the bundle recursively.

Safe by default: it does nothing as long as an app is not listed in `LCExtForward.apps`.
Apps without extensions are never affected. If it accidentally runs in a guest instead of
the host, it has no effect (it checks for `LCUtils`). If anything looks wrong, it signs the
bundle unchanged.

### Alternative without the host tweak: `patch_appex.py`

The same conversion (byte-identical) can be done up front on a computer:

```
python3 patch_appex.py Madeira.ipa Madeira-lc.ipa
```

Then import the patched IPA into LiveContainer and follow only part **B** (without steps 6 and 9).

## Building

On macOS with Xcode:

```
make           # both dylibs, without logging
make LOG=1     # per-app tweak with logging
```

Releases are built automatically by GitHub Actions (`.github/workflows/release.yml`):
go to **Actions → Release → Run workflow** and enter a new version (e.g. `v1.1.1`).
