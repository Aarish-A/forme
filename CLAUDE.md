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
make run         # build, install and launch in the simulator
make device      # same, on a connected iPhone
make logs        # stream the app's Log.* output from the simulator
make diag        # pull scan diagnostics off the connected iPhone
make diag-sim    # same, from the simulator
make unit        # unit tests only — use this while iterating
make test        # unit + UI tests
make lint        # SwiftLint, strict
make ci          # everything CI runs
```

`make` alone lists the rest. Default simulator is iPhone 17 Pro; override with
`make test SIMULATOR="iPhone Air"`. `make device` finds the connected iPhone
itself — pass `DEVICE_ID=` only when more than one is attached.

Builds go to `./DerivedData`, not Xcode's global cache, so the `.app` sits at a
predictable path for `simctl`. Xcode's UI keeps its own cache, so building both
ways compiles twice.

The simulator has no camera: anything touching capture, and any real check of
Vision performance, has to run on a device.

**A scan writes a diagnostics report** (`Application Support/Diagnostics/`, DEBUG
builds only) with stage counts and the distribution behind every threshold.
`make diag` pulls it off a cabled iPhone; the finished-scan screen also has a
"Scan Report" button that shares the file. Tune thresholds from those
distributions, not from screenshots — a histogram of face sizes would have caught
the dead identity gate in seconds.

**Reading `Log.*` from a real device: use the Xcode MCP.** When the app is
launched from Xcode (`RunProject`, or the Run button), `GetConsoleOutput` returns
its OSLog — on a physical device, with subsystem/category metadata, regex and
severity filters. That is the live-narration channel. Note what does *not* work,
so it isn't re-investigated: `log stream` has no device flag, `log collect`
needs root, and `devicectl … --console` bridges stdout only, which `Logger` does
not write to. `make logs` covers the simulator.

Logs narrate; the report measures. Reach for the report for anything shaped like
a distribution — that's what a log stream is bad at.

The report may never contain anything about what the user wears or looks like —
counts, durations and scalar histograms only. See `ScanReport`'s doc comment.

SwiftFormat and SwiftLint versions are pinned in `.tool-versions` and installed
at those exact versions in CI. `make tools` checks the local ones match — they
have to, because a newer local SwiftFormat rewrites files that CI's pinned one
then rejects. Bumping a pin means running `make format` in the same commit.

## Worktrees

**Commit before you split.** `claude --worktree <name>` checks out into
`.claude/worktrees/<name>/` on a branch taken from origin's default branch, and
a worktree never carries uncommitted work. Split with a dirty tree and the agent
builds an older app than the one in front of you.

**Delete the app from the phone when you switch worktrees.** Every branch
installs the same `com.forme.app`, and an upgrade-install keeps its Application
Support directory — so one branch's code opens another branch's wardrobe data,
which reads as a bug in whatever you're testing.

`.worktreeinclude` copies the gitignored files a worktree can't build properly
without. Add to it rather than copying files by hand.

`DERIVED := DerivedData` is relative, so each worktree builds into its own
(~800 MB) and two builds never fight over one build database.

Three things stay serial no matter how many worktrees are open:

- **The iPhone.** There's one of it, and the simulator has no camera, so capture
  and any real check of Vision performance queue up behind you.
- **`.tool-versions` bumps.** SwiftFormat and SwiftLint are single global
  binaries shared by every worktree and by the format-on-write hook. A bump
  breaks `make tools` everywhere at once.
- **Supabase schema changes.** Every worktree points at the same project ref
  with MCP write access. Worktrees isolate files, not the database.

If concurrent `make unit` runs start failing strangely, it's the two of them
installing `com.forme.app` onto one simulator mid-test: put
`SIMULATOR := iPhone Air` in one worktree's `Local.mk`. Not worth doing
pre-emptively.

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
  Under approachable concurrency, a `nonisolated` **async** function runs on
  its *caller's* actor — `nonisolated` alone no longer means "off main". Mark
  heavy async work (image decode/encode, Vision, PhotoKit fetches)
  `@concurrent` so it always leaves the calling actor.
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
- Swift files are auto-formatted on write by a hook, so don't hand-align code.

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
- The Supabase MCP server (`.mcp.json`) has **write access** to the live
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
</content>
</invoke>
