# Forme

An iOS app that helps people become the most confident version of themselves by
making fashion easier and more accessible.

Keep that sentence in mind when making product calls. Forme is not a shopping
app or a styling encyclopaedia — it exists to remove the friction and
self-doubt between someone and getting dressed. Two questions decide most
design arguments:

1. Does this make the user feel more capable, or more judged?
2. Could someone with no interest in fashion use this on a rushed morning?

Features that fail either question are the wrong features, however well built.

## Commands

```sh
make bootstrap     # one-time setup on a fresh clone
make build         # build for the simulator
make test          # unit + UI tests
make unit          # unit tests only (fast — use this while iterating)
make lint          # SwiftLint, strict
make format        # rewrite with SwiftFormat
make ci            # everything CI runs
```

Default simulator is iPhone 17; override with `make test SIMULATOR="iPhone Air"`.

## Stack

- **iOS 26+**, Swift 6 language mode, SwiftUI. No UIKit unless SwiftUI genuinely
  cannot do the job.
- **Supabase** (`supabase-swift`) for auth, database, and storage.
- **Swift Testing** (`@Test`, `#expect`) for unit tests. XCTest only in
  `FormeUITests`, because XCUITest still requires it.
- Xcode 27, `objectVersion = 90` project format with file-system synchronized
  groups.

## Layout

```
Config/          xcconfig build settings (see "Build settings" below)
Forme/
  App/           entry point, dependency graph, root navigation
  Models/        plain Sendable value types
  Services/      protocol-defined I/O; Supabase lives under Services/Supabase
  State/         @Observable stores that views watch
  DesignSystem/  design tokens and shared view modifiers
  Features/      one folder per feature, views inside
  Support/       cross-cutting helpers (logging)
  Resources/     asset catalog
FormeTests/      Swift Testing unit tests
FormeUITests/    XCUITest end-to-end tests
```

**Files are added to targets automatically.** The project uses synchronized
groups, so creating a file under `Forme/` puts it in the app target with no
project file edit. Never hand-edit `project.pbxproj` to add a source file.

## Architecture

Three layers, and the direction of dependency matters:

```
View  →  Store (@Observable)  →  Service (protocol)  →  Supabase
```

- **Views** are dumb. They read state and call store methods. No networking, no
  business rules, no `SupabaseClient`.
- **Stores** (`State/`) hold observable state and orchestrate. `SessionStore` is
  the reference example.
- **Services** (`Services/`) are protocols. Every protocol has a real
  implementation and an in-memory one. Views and stores depend on the protocol,
  never the concrete type — that is what keeps previews and tests offline.
- **Models** (`Models/`) are our own types, not Supabase's. Mapping happens at
  the service boundary, so a backend change never reaches a view.

Dependencies are assembled once in `AppEnvironment.live()` and reach views via
`@Environment(\.appEnvironment)`. There are no singletons. Adding a service
means: define the protocol, write the real and in-memory implementations, add a
property to `AppEnvironment`, wire it in `live()` and `preview`.

## Conventions

- **Concurrency**: the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  so types are main-actor isolated unless marked `nonisolated`. Mark value types
  and stateless helpers `nonisolated`. Don't add `@MainActor` — it's the default.
  `XCTestCase` subclasses must be `nonisolated`.
- **Explicit imports**: `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is on.
  A file using `Logger` needs `import OSLog` even if another file already has it.
- **Logging**: `Log.app`, `Log.auth`, `Log.network`, `Log.feature`. Never
  `print` — SwiftLint flags it. Interpolated values are redacted by default;
  add `privacy: .public` only for values that are safe in a system log. Never
  log emails, tokens, or anything about what a user wears.
- **Design tokens**: use `Theme.Spacing`, `Theme.Radius`, `Theme.Typography`
  rather than literal numbers. If a value isn't in the scale, question the
  layout before adding one.
- **Previews**: every view gets a `#Preview` using `.preview` environments.
  A view that can't be previewed usually has a dependency in the wrong place.
- **Force unwrapping** is a lint error in app code. In tests use
  `try #require(...)`.
- **Accessibility** is not optional. Dynamic Type must work at accessibility
  sizes, controls need labels, and colour is never the only signal. This app is
  about making people feel capable; an interface they can't read undoes that.

## Build settings

All build settings live in `Config/*.xcconfig`, not in the Xcode UI. Changing a
setting in Xcode's Build Settings pane writes it into `project.pbxproj` where it
silently overrides the xcconfig — edit the xcconfig instead.

```
Shared.xcconfig      every target, every configuration
Debug.xcconfig       local development   (includes Shared)
Release.xcconfig     TestFlight/App Store (includes Shared)
Forme.xcconfig       app target
FormeTests.xcconfig  unit test bundle
FormeUITests.xcconfig UI test bundle
```

## Supabase

Credentials come from `Config/Secrets.xcconfig` (gitignored). Copy
`Config/Secrets.example.xcconfig` and fill it in; `make bootstrap` does this.
They flow xcconfig → Info.plist → `SupabaseConfig` → `SupabaseAuthService`.

**Without credentials the app still builds and runs**, falling back to
`InMemoryAuthService`. Preserve that property — it's what keeps a fresh clone
and CI working.

### MCP server

`.mcp.json` (committed) points at the hosted Supabase MCP server for project
`gknqnstlxjpcrqakvlew`, authenticated with a personal access token read from
`SUPABASE_ACCESS_TOKEN`. That token lives in `.claude/settings.local.json`,
which is gitignored — it is a full-account credential, unlike the anon key.

The server has **write access**. Append `&read_only=true` to the URL to make it
read-only, and do that before ever pointing it at production. Note that the
`supabase db push` / `db reset` deny rules in `.claude/settings.json` only cover
the CLI — they do not restrain MCP tools.

Two rules that matter:

- The **anon key** ships in the binary and that is fine; Row Level Security is
  what protects data. The **service role key** must never appear in this repo
  or on a device.
- Every table needs RLS enabled with a policy scoped to `auth.uid()`. A table
  without RLS is public. Treat wardrobe contents as sensitive — what someone
  owns and how they see themselves is personal.

## Gotchas

- **The `//` trap in xcconfig**: `//` starts a comment anywhere on a line, so
  `https://x.supabase.co` silently becomes `https:`. Write `SUPABASE_URL` as a
  bare host and let `SupabaseConfig` add the scheme. If a full URL is
  unavoidable, the escape goes *between* the slashes: `https:/$()/x.example.com`.
  `SupabaseConfig` rejects the truncated form, and there's a test for it.
- **Custom Info.plist keys**: `INFOPLIST_KEY_*` only passes through keys Xcode
  recognises. Custom keys must be declared in `Config/Info.plist`, which Xcode
  merges with the generated one. Adding `INFOPLIST_KEY_MY_THING` alone silently
  does nothing.
- **Case-only renames**: the source directory is `Forme`, capitalized. macOS is
  case-insensitive, so a rename that only changes case needs `git mv`.
- **Stale SourceKit errors**: after adding files, the Xcode index may report
  "cannot find type in scope" until it catches up. Trust `make build`, not the
  editor.
