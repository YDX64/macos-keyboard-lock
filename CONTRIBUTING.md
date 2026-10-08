# Contributing

Thanks for helping! The project is small on purpose: Swift only, no dependencies, one build script.

## Build and test

```bash
./build.sh              # builds KeyboardLock.app (needs Xcode or the Command Line Tools)
./tools/selftest.sh     # helper protocol + installer, runs without root, a keyboard or a password
```

`selftest.sh` and the strings check also run in CI on every push and pull request.

## Work on the UI without touching a keyboard

`tools/fake-helper.py` pretends to be the root service, so you can iterate on the window, menu bar and Dock
without installing anything:

```bash
./tools/fake-helper.py /tmp/kl-fake.sock --state locked &    # unlocked | locked | waiting
open -n --env KK_SOCKET=/tmp/kl-fake.sock KeyboardLock.app
```

## Add a language

1. Copy `Resources/en.lproj` to `Resources/<code>.lproj` (for example `de.lproj`) and translate
   `Localizable.strings` and `InfoPlist.strings`. Keep every key and every `%@` / `%d` placeholder.
2. Add the code to `Localizer.supported` in `Sources/Localizer.swift`, a case to `LanguageChoice`, its
   `lang.<code>` key to every `Localizable.strings`, and the case to `languageName(_:)` in
   `Sources/ContentView.swift`.
3. Add the language to `CFBundleLocalizations` in `Info.plist`.
4. Run `./tools/check-strings.py`. It fails when a language misses a key or changes a placeholder.

English is the source of truth and the fallback for missing keys.

## Pull requests

- Keep changes focused and the code dependency-free.
- Anything that touches `Sources/Helper.swift`, `Sources/Installer.swift` or `Sources/HelperControl.swift`
  needs a matching case in `tools/selftest.sh` and a note in `SECURITY.md` if the trust model changes.
- Bump `KK.protocolVersion` in `Sources/Constants.swift` when the helper changes, so installed copies show
  *Update*.
- Do not log or store key events. The helper must never register input callbacks.

## Reporting bugs

Open an issue with your macOS version, the keyboard model and the text of the notice the app showed. For
security problems please follow [SECURITY.md](SECURITY.md).
