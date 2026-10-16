# Testing

Use the pinned Flutter SDK through FVM. From the repository root:

```sh
fvm install
fvm flutter pub get
fvm flutter analyze
fvm flutter test
python3 -m unittest discover -s scripts -p 'test_*.py'
swift test --package-path macos/HerdrHelper
```

Optional SSH and installed-CLI checks use disposable servers, not live sessions.
See the README for their environment variables and Python dependencies.
Rebuild bundled bridge assets with `scripts/build-bridge` after editing the
Python bridge or restricted catalog gate.

Before distributing a build, check physical keyboard input, clipboard paste,
Finder image drops, scrolling, rename/clear, and reconnect behavior on the
intended platforms. Automated tests do not prove every native input path.
Use disposable terminals for checks that send input or change sessions.
Production signing and notarization are separate release steps.
