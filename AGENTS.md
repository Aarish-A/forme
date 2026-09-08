# Forme

An iOS app that helps people become the most confident version of themselves by
making fashion easier and more accessible.

Forme is not a shopping app or a styling encyclopaedia — it exists to remove the
friction and self-doubt between someone and getting dressed. Two questions
settle most design arguments:

1. Does this make the user feel more capable, or more judged?
2. Could someone with no interest in fashion use this on a rushed morning?

A feature that fails either is the wrong feature, however well built.

## How to work with me

I'm fluent in React, new to Swift and Xcode.

- **Teach as you go.** Explain the concept behind a change at a high level, with
  a React analogy where there's an honest one. Detail only where it changes what
  I'd do.
- **Be brief.** Lead with the big picture. Don't narrate options you won't take.
- **Simplicity is the bar.** Before proposing anything, ask "would a senior
  engineer call this overcomplicated?" Abstractions and performance work must
  earn their place. If fixes are stacking on fixes, stop and re-examine the
  approach rather than adding another layer.
- **Think from every angle** — product, UX, design, data, engineering — before
  landing. Where there's a real tradeoff, name it and recommend one. Don't
  assume, and don't hide confusion; ask.
- **Look things up.** Swift, SwiftUI and Supabase move fast and your training
  may be stale. Search the web or use the Supabase MCP for current docs rather
  than guessing or reinventing something already solved.
- **Push back.** If I'm wrong, say so and why. Agreement I didn't earn is worse
  than useless.

## Commands

```sh
make bootstrap   # one-time setup on a fresh clone
make build       # build for the simulator
make unit        # unit tests only — use this while iterating
make test        # unit + UI tests
make lint        # SwiftLint, strict
make ci          # everything CI runs
```

`make` alone lists the rest. Default simulator is iPhone 17; override with
`make test SIMULATOR="iPhone Air"`.

SwiftFormat and SwiftLint versions are pinned in `.tool-versions` and installed
at those exact versions in CI. `make tools` checks the local ones match — they
have to, because a newer local SwiftFormat rewrites files that CI's pinned one
then rejects. Bumping a pin means running `make format` in the same commit.

## Architecture

```
View  →  Store (@Observable)  →  Service (protocol)  →  Supabase
```

- **Views** (`Features/`) read state and call store methods. No networking, no
  business rules, no `SupabaseClient`.
- **Stores** (`State/`) hold observable state and orchestrate — `SessionStore`
  is the reference example.
- **Services** (`Services/`) are protocols, each with a real and an in-memory
  implementation. Depend on the protocol, never the concrete type — that's what
  keeps previews and tests offline.
- **Models** (`Models/`) are our types. Map from Supabase's at the service
  boundary, so a backend change never reaches a view.

The graph is assembled once in `AppEnvironment.live()` and reaches views via
`@Environment(\.appEnvironment)`. No singletons.

**Files join targets automatically** — creating a file under `Forme/` is enough.
Never hand-edit `project.pbxproj` to add a source file.

## Conventions

- **SwiftUI only** — no UIKit unless SwiftUI genuinely can't do the job.
- **Swift Testing** (`@Test`, `#expect`) for unit tests, never XCTest. XCTest
  only in `FormeUITests`, because XCUITest still requires it.
- **Concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are
  main-actor isolated by default. Never add `@MainActor`; mark value types and
  stateless helpers `nonisolated`. `XCTestCase` subclasses must be `nonisolated`.
- **Explicit imports**: member import visibility is on, so a file using `Logger`
  needs its own `import OSLog`.
- **Logging**: `Log.app` / `.auth` / `.network` / `.feature`, never `print`.
  Never log emails, tokens, or anything about what a user wears.
- **Design tokens**: `Theme.Spacing`, `Theme.Radius`, `Theme.Typography` over
  literal numbers. If a value isn't in the scale, question the layout first.
- **Previews**: every view gets a `#Preview` using `.preview` environments. A
  view that can't be previewed usually has a dependency in the wrong place.
- **Comments** explain *why*, and only where the reason isn't obvious.
- **No force unwrapping** in app code; tests use `try #require(...)`.
- **Accessibility**: Dynamic Type at accessibility sizes, labelled controls,
  colour never the only signal. An interface someone can't read undoes the
  whole point of the app.
- Swift files edited with `apply_patch` are formatted by the Codex PostToolUse
  hook after it has been trusted. For shell-based edits, run SwiftFormat on the
  changed files explicitly. Do not hand-align code.

## Build settings

All build settings live in `Config/*.xcconfig`. Editing Build Settings in the
Xcode UI writes into `project.pbxproj`, which silently overrides the xcconfig —
edit the xcconfig instead.

A setting passed on the `xcodebuild` command line applies to **every** target in
the build, SwiftPM dependencies included. That's why CI passes the project's own
`FORME_WARNINGS_AS_ERRORS=YES` rather than `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`:
only our xcconfigs read the custom name, so dependencies — which Xcode compiles
with `-suppress-warnings` — never see the conflicting flag.

## Supabase

Credentials live in `Config/Secrets.xcconfig` (gitignored; `make bootstrap`
creates it) and flow xcconfig → Info.plist → `SupabaseConfig` → services.

**Without credentials the app still builds and runs**, falling back to
`InMemoryAuthService`. Preserve that — it's what keeps a fresh clone and CI
working.

- The **anon key** ships in the binary and that's fine; RLS is what protects
  data. The **service role key** must never appear in this repo or on a device.
- Every table needs RLS enabled with a policy scoped to `auth.uid()`. A table
  without RLS is public. Treat wardrobe contents as sensitive — what someone
  owns and how they see themselves is personal.
- The Supabase MCP server (`.codex/config.toml`) has **write access** to the live
  project, and the `supabase db push`/`db reset` deny rules only cover the CLI.
  Confirm with me before any MCP call that writes.

## Gotchas

- **`//` in xcconfig starts a comment anywhere on a line**, so
  `https://x.supabase.co` silently becomes `https:`. Write `SUPABASE_URL` as a
  bare host and let `SupabaseConfig` add the scheme. If a full URL is
  unavoidable, escape *between* the slashes: `https:/$()/x.example.com`.
- **Custom Info.plist keys**: `INFOPLIST_KEY_*` only passes keys Xcode
  recognises. Custom keys must be declared in `Config/Info.plist`. Adding
  `INFOPLIST_KEY_MY_THING` alone silently does nothing.
- **Case-only renames** need `git mv` — macOS is case-insensitive.
- **Stale SourceKit errors**: after adding files the Xcode index may report
  "cannot find type in scope". Trust `make build`, not the editor.

## Codex permissions

- Do not read `Config/Secrets.xcconfig`, `**/*.p8`, `**/*.p12`, or
  `**/*.mobileprovision`.
- Do not run `supabase db reset` or `supabase db push`. The corresponding
  command prefixes also have deny rules in `.codex/rules/forme.rules`.
- These instructions preserve the Claude read restrictions as guidance; they
  are not a filesystem permission boundary. Command rules apply to matching
  prefixes and do not replace the sandbox or the MCP write confirmation above.
- The usual make, Xcode, simulator, formatter, Git inspection/staging, and
  Supabase inspection commands remain routine work under Codex's configured
  sandbox and approval policy. Claude's allow list does not grant a sandbox bypass.
- Supabase authentication uses `SUPABASE_ACCESS_TOKEN` from Codex's environment.
  Codex does not load `.claude/settings.local.json`; never copy its token into
  tracked configuration or print it. Supply the variable securely before launch.
