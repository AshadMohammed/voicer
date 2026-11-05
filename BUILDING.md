# Building Voicer

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools
- Git

## Local Build

```bash
git clone https://github.com/AshadMohammed/voicer.git
cd voicer
make local
open ~/Downloads/Voicer.app
```

`make local` prepares a macOS-only `whisper.xcframework` in `~/VoiceInk-Dependencies` (with `scripts/build-whisper-xcframework-macos.sh`, so the iOS, tvOS and visionOS platforms are not needed), builds Release in `.local-build`, and copies `Voicer.app` to `~/Downloads`.

It uses `LocalBuild.xcconfig`, `VoiceInk.local.entitlements`, and the `LOCAL_BUILD` Swift flag. Without an override, it uses the `Voicer Local Signing` certificate if you created one, else the only available Apple Development identity, and falls back to ad-hoc signing when neither is found.

To stop macOS asking for permissions (Accessibility, Microphone, ...) after every rebuild, run this once. It creates a free self-signed certificate in your login keychain, and macOS asks for your password to trust it:

```bash
make signing-cert
```

The next `make local` signs with it, and the permissions you grant then survive later rebuilds.

Choose an identity explicitly:

```bash
make local LOCAL_CODESIGN_IDENTITY="<SHA or name>"
```

Force ad-hoc signing:

```bash
make local LOCAL_CODESIGN_IDENTITY=-
```

Local builds do not include iCloud dictionary sync or automatic updates. Ad-hoc builds may require macOS permissions again after rebuilding.

## Other Commands

- `make check` — verify required tools
- `make whisper` — prepare `whisper.xcframework`
- `make build` — build the standard Debug configuration
- `make dev` — build and launch `VoiceInk Dev.app`
- `make run` — launch `~/Downloads/Voicer.app`, or the first app found in DerivedData
- `make release` — create the signed release package
- `make release-setup` — configure release notarization credentials
- `make clean` — remove `~/VoiceInk-Dependencies`
- `make help` — list all commands

## Build with Xcode

```bash
make setup
open VoiceInk.xcodeproj
```

Select the `VoiceInk` scheme. Run builds `VoiceInk Dev.app`; Archive uses Release. `LOCAL_BUILD` applies only through `make local`.

## Troubleshooting

- Run `make check` to verify the required tools.
- Run `make whisper` if the framework is missing.
- If several Apple Development identities exist, set `LOCAL_CODESIGN_IDENTITY` explicitly.
- For additional help, open a [GitHub issue](https://github.com/AshadMohammed/voicer/issues).
