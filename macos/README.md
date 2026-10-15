# PIME for macOS

An InputMethodKit front end that runs PIME's Python backend on macOS.
Only the chewing input method (新酷音) is supported.

<!-- Written with assistance from Claude Code (Claude Opus 5.5). -->

## Requirements

* macOS 26 on Apple silicon (arm64)
* Xcode Command Line Tools (`xcode-select --install`); full Xcode is not needed
* An "Apple Development" signing identity in the login keychain, or pass
  `CODESIGN_IDENTITY=-` to sign ad hoc

## Build and install

    git submodule update --init libchewing
    macos/scripts/build_app.sh     # builds macos/build/PIME.app
    macos/scripts/install.sh       # copies it to ~/Library/Input Methods

`build_app.sh` downloads a pinned python-build-standalone runtime (checked
against its SHA-256) and a hash-pinned tornado wheel the first time. The
download is cached in `macos/build/cache`.

The first time, add the input method in System Settings > Keyboard > Text
Input > Input Sources > Edit > + > Chinese, Traditional > 新酷音 (PIME).
macOS 26 does not let `install.sh` enable it on its own.

Run the unit tests with:

    macos/scripts/test.sh

## Installer package

To give PIME to others, build an installer package from
`macos/build/PIME.app`:

    macos/scripts/build_pkg.sh     # builds macos/build/PIME-<version>-arm64.pkg

The package installs PIME.app into `~/Library/Input Methods` without an
administrator password, and runs the same steps as `install.sh`. It is
used instead of a zip or disk image because files installed by Installer
are not quarantined, so Gatekeeper does not block the input method, which
is not notarized.

The package itself is not signed, so macOS refuses to open the downloaded
package at first. Open it once, then click Open Anyway in System Settings >
Privacy & Security, or remove the quarantine attribute:

    xattr -d com.apple.quarantine PIME-*.pkg

To install it from the command line:

    installer -pkg PIME-*.pkg -target CurrentUserHomeDirectory

## Usage

The keys are the same as on Windows, e.g. Shift switches between Chinese
and English and Shift+Space switches between half and full width. A short
label (中/英/全形/半形) next to the caret shows mode changes.

Settings, the user phrase editor and the other items of the Windows
language bar menu are in the input menu of the menu bar.

Differences from Windows:

* Command shortcuts always go to the application.
* Bopomofo keys follow US key positions regardless of the macOS keyboard
  layout.
* Simplified Chinese output is disabled because OpenCC is not bundled.
* The candidate window cannot be clicked.

## Files

| What | Where |
| --- | --- |
| Settings, symbols.dat, swkb.dat, chewing.sqlite3 | `~/Library/Application Support/PIME/chewing` |
| Backend stderr and errors | `~/Library/Logs/PIME/backend.log`, `python_backend.log` |

To keep your user phrases from Windows, copy the files in
`%APPDATA%\PIME\chewing` to `~/Library/Application Support/PIME/chewing`.
libchewing is built from the same source as the Windows `chewing.dll`, so
`chewing.sqlite3` is compatible. The build applies the fixes in
`macos/patches/libchewing` to a copy of that source.

## Uninstall

    pkill -x PIME
    rm -rf ~/Library/Input\ Methods/PIME.app
    pkgutil --volume ~ --forget org.easyime.inputmethod.PIME   # if installed from the package

Then remove 新酷音 (PIME) from the input sources in System Settings.

## Troubleshooting

* **Selecting the input method does nothing and the log shows
  `imklaunchagent: LaunchInputMethod() Error, status=-50`.**
  The system launcher may not know a newly installed input method until
  the next login. `install.sh` starts PIME once to work around this; log
  out and back in if it happens again.
* **Two copies of PIME.app with the same bundle ID** (e.g. the one in
  `macos/build`) can confuse LaunchServices. Unregister the build output:

      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u macos/build/PIME.app

## Design

    key events (InputMethodKit)
          |
    PIME.app (Swift): InputController -> ClientSession
          |
      (stdin/stdout, the same protocol as PIMELauncher)
          |
    Contents/Resources/python/bin/python3 server.py (chewing only)

* `Sources/PIMECore`: platform-neutral code with unit tests. It maps macOS
  key events to the Win32-style key events the Python backends expect
  (`KeyMapping.swift`), runs the backend (`BackendProcess.swift`), and
  follows the request flow of `PIMETextService/PIMEClient.cpp`
  (`ClientSession.swift`).
* `Sources/PIME`: the InputMethodKit app, candidate window and input menu.
* There is no PIMELauncher on macOS: the app starts the Python backend
  itself and restarts it after it crashes or stops answering.
* Each InputMethodKit client gets its own backend client, activated once.
  Focus changes do not reset the Chinese/English mode.
* InputMethodKit does not send key up events, so the app sends one right
  after each key down, and turns `flagsChanged` events into modifier key
  down/up events.
