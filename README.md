# LCExtForward

A tweak for [LiveContainer](https://github.com/LiveContainer/LiveContainer) that lets guest apps
start their **own private app extensions**, which are otherwise missing inside the container –
e.g. Madeira's memory host or Reynard's Gecko child processes. The extension then runs inside
LiveContainer's `LiveProcess.appex`.

> This only works for extensions the app starts **itself** via `NSExtension` (helper processes).
> Widgets, share, keyboard and notification extensions do not work – those are launched by iOS.

## Download

Prebuilt files are available under **[Releases](../../releases/latest)** (arm64, iOS 16+):

| File | Purpose |
|---|---|
| `LCExtForward.dylib` | The tweak – one dylib for everything |
| `LCExtForward-log.dylib` | Same as above, with logging (for troubleshooting only) |
| `LCExtForward.apps` | Opt-in list: which apps the tweak handles |
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

### A) Install the tweak (once)

1. Put `LCExtForward.dylib` **and** `LCExtForward.apps` into the **global** tweak folder,
   both directly in the folder (no subfolder):
   Files app → "On My iPhone" → **LiveContainer → `Tweaks/`**
   (with shared bundle/SideStore: app group → `LiveContainer/Tweaks/`).
2. Let LiveContainer **sign** the tweaks (tweak manager).
3. **Settings → Developer → enable "Load Tweaks to Self"**
   (`LCLoadTweaksToSelf`; German UI: „Tweaks selber in LiveContainer laden").
4. **Fully restart** LiveContainer (close it from the app switcher and reopen it).

### B) Add an app

5. Add the app to `LCExtForward.apps` – one app per line, as **bundle ID** or **`.app` name**:
   ```
   com.willfaust.madeora.app
   com.minh-ton.Reynard
   ```
   `*` = all apps, `#` = comment. Empty file = nothing is touched.
6. **Import** the IPA into LiveContainer as usual, if not done yet.
7. **Re-sign** the app in LiveContainer **once**. The tweak converts its appex(es) during this step.
8. Launch the app.
    - **Gecko apps (Reynard):** the **first launch takes longer** – the frameworks
      (XUL/GeckoView, a few hundred MB) are copied into the app group once.
      Later launches are fast.

> Apps without extensions, or apps not on the list, are **never** modified, and the tweak does
> nothing in them.

> **Order matters:** add the app to `LCExtForward.apps` **first**, **then** sign the app.
> The conversion happens while signing – if the app is not on the list at that point, nothing is
> converted and the extension will not start.

### Upgrading from 1.x

1.x had two dylibs. Remove `LCExtForwardHost.dylib` from the global tweak folder and
`LCExtForward.dylib` from every per-app tweak folder, then follow part A. Apps that were
already converted do not need to be re-signed.

---

## Troubleshooting

Put **`LCExtForward-log.dylib`** into the global tweak folder instead of `LCExtForward.dylib`
(sign it, restart LiveContainer) and try again. It writes `LCExtForward.log` to the Documents
folder of each data container:

- **Conversion while signing:** Files → LiveContainer → `LCExtForward.log`
- **Forwarding in the app:** Files → LiveContainer → **Data → Application → (the app's container) → `Documents/LCExtForward.log`**

| Log line | Meaning |
|---|---|
| `host role: converting appexes …` | The tweak is loaded into LiveContainer itself |
| `converted ….appex/…` | An appex was converted while signing |
| `not listed in LCExtForward.apps, forwarding disabled` | Add the app to the list |
| `forwarding … to … LiveProcess` | Forwarding works |
| `staged Frameworks (…)` | Frameworks were copied (Gecko apps only) |
| `running com.…Helper …` | The extension is running |
| `dlopen … failed: … @rpath/…` | A library is missing (frameworks not copied/signed) |
| `dlopen … sandbox blocked mmap()` | The appex was not converted → check "Load Tweaks to Self" and the list, then re-sign |

## Limitations

- Only extensions the app starts itself via `NSExtension`. Both variants are intercepted:
  `…completion:` (e.g. Madeira) and `…error:` (e.g. Reynard/Gecko).
- Every forwarded extension runs as `com.apple.ar.viewer` (without the Jetsam memory limit),
  regardless of what it declares.
- Storyboard-based extensions (`NSExtensionMainStoryboard`) are not supported.
- So far only tested on a device with Madeira.

---

## Technical details

### One dylib, three roles

The same `LCExtForward.dylib` is loaded into three kinds of processes and does a different job in each:

| Process | How it gets there | Job |
|---|---|---|
| LiveContainer itself | "Load Tweaks to Self" | Converts appexes of listed apps while signing (see below) |
| Guest app | Global tweak folder | Forwards the app's own extensions to LiveProcess |
| LiveProcess | Copied to the app group, loaded as payload | Loads and runs the appex |

In a guest app that is not on the list, the tweak only installs its hook and otherwise does
nothing: it acts only when iOS does not know an extension the app asks for.

### How forwarding works

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

### Conversion while signing

In LiveContainer itself, the tweak hooks the signing step (`+[LCUtils signAppBundleWithZSign:]`)
and converts every `PlugIns/*.appex` of a listed app into a `dlopen`-able `MH_DYLIB`
**before** ZSign signs the bundle recursively. The list is re-read on every signing.

Safe by default: nothing is converted as long as an app is not listed in `LCExtForward.apps`.
Apps without extensions are never affected. The hook only exists where `LCUtils` can sign,
i.e. in LiveContainer itself. If anything looks wrong, the bundle is signed unchanged.

### Alternative without "Load Tweaks to Self": `patch_appex.py`

The same conversion (byte-identical) can be done up front on a computer:

```
python3 patch_appex.py Madeira.ipa Madeira-lc.ipa
```

Import the patched IPA, then put `LCExtForward.dylib` (without `LCExtForward.apps`) into a
**per-app** tweak folder assigned to that app. Without a list file next to it, forwarding is
always active for the apps the folder is assigned to.

## Building

On macOS with Xcode:

```
make           # without logging
make LOG=1     # with logging
```

Releases are built automatically by GitHub Actions (`.github/workflows/release.yml`):
go to **Actions → Release → Run workflow** and enter a new version (e.g. `v2.0.1`).
