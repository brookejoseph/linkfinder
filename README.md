# LinkFinder

LinkFinder is a Swift CLI for best-effort macOS app deep-link discovery. Give it a `.app` bundle and it looks for:

- URL schemes declared in `CFBundleURLTypes`
- associated domains and activity types where they are present
- URL-like strings in bundle resources and native binaries
- inferred routes made by combining declared schemes with route-like tokens found in the app
- System Settings pane identifiers that can often be opened with `x-apple.systempreferences:`

It cannot guarantee every private route. Apps can build routes dynamically, gate them behind state, or accept only undocumented parameters. The goal is to give you a useful starting map and a way to verify candidates.

Candidate confidence levels:

- `declared`: the scheme is registered in `Info.plist`
- `found`: the full URL-like string appears in the app
- `likely`: LinkFinder knows a special platform convention, such as System Settings pane URLs
- `inferred`: LinkFinder combined a declared scheme with a route-like token such as `devices`, `items`, or `people`

## Build

On a healthy Xcode or Command Line Tools install:

```sh
swift build
```

If `swift build` fails because `xcrun` cannot find the macOS SDK platform path, this repo also includes a direct `swiftc` build path:

```sh
make build
```

Run the debug binary:

```sh
.build/linkfinder scan "/System/Applications/System Settings.app"
```

Install locally:

```sh
make build
cp .build/linkfinder /usr/local/bin/linkfinder
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
