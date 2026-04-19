# LinkFinder

LinkFinder is a Swift CLI for best-effort macOS app deep-link discovery. Give it a `.app` bundle and it looks for:

- URL schemes declared in `CFBundleURLTypes`
- associated domains and activity types where they are present
- URL-like strings in bundle resources and native binaries
- System Settings pane identifiers that can often be opened with `x-apple.systempreferences:`

It cannot guarantee every private route. Apps can build routes dynamically, gate them behind state, or accept only undocumented parameters. The goal is to give you a useful starting map and a way to verify candidates.

## Build

```sh
swift build
```

If `swift build` fails because `xcrun` cannot find the macOS SDK platform path, compile directly with the installed SDK:

```sh
mkdir -p .build
swiftc -module-cache-path /tmp/linkfinder-module-cache \
  -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX13.3.sdk \
  Sources/LinkFinder/main.swift \
  -o .build/linkfinder
```

Run the debug binary:

```sh
.build/debug/linkfinder scan "/System/Applications/System Settings.app"
```

Install locally:

```sh
swift build -c release
cp .build/release/linkfinder /usr/local/bin/linkfinder
```

## Usage

```sh
linkfinder scan <App.app> [--json] [--limit N]
linkfinder scan <App.app> --verify [--verify-limit N] [--filter REGEX]
```

Examples:

```sh
linkfinder scan "/System/Applications/System Settings.app"
linkfinder scan "/Applications/Obsidian.app" --json
linkfinder scan "/System/Applications/System Settings.app" --verify --filter General
```

`--verify` calls `/usr/bin/open` on candidate URLs, so use it intentionally. It may launch apps or navigate existing app windows.
