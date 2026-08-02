# Forme

Helping people become the most confident version of themselves by making
fashion easier and more accessible.

## Getting started

Requires Xcode 27 or later.

```sh
git clone <this repo>
cd forme
make bootstrap
make test
make run
```

`make run` builds and launches in the simulator; `make device` does the same on
a connected iPhone. Open `Forme.xcodeproj` when you want previews or the
debugger.

The app builds and runs without Supabase credentials — it falls back to
in-memory auth, so you can work on UI immediately. To connect a real backend,
fill in `Config/Secrets.xcconfig` (created by `make bootstrap` from
`Config/Secrets.example.xcconfig`).

## Layout

| Path            | What's in it                                    |
| --------------- | ----------------------------------------------- |
| `Forme/`        | App source                                      |
| `FormeTests/`   | Unit tests (Swift Testing)                      |
| `FormeUITests/` | End-to-end tests (XCUITest)                     |
| `Config/`       | Build settings as xcconfig files                |
| `CLAUDE.md`     | Architecture, conventions, and gotchas          |

`CLAUDE.md` is the engineering guide — read it before making changes. It's
written for Claude Code but applies equally to humans.

## Tasks

Run `make` with no arguments to list everything. The common ones:

```sh
make run      # build and launch in the simulator
make device   # build and launch on a connected iPhone
make logs     # stream the app's log output
make build    # build for the simulator
make unit     # unit tests only — fast
make test     # unit + UI tests
make lint     # SwiftLint
make format   # SwiftFormat
make ci       # everything CI runs
```

## Tech

iOS 26+ · Swift 6 · SwiftUI · Supabase
