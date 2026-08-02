# The scan pipeline: design and evolution plan

## Field test 2: the identity gate was structurally dead

The second field test imported a stranger couple's entire engagement shoot. The
cause was arithmetic, not judgement:

- Faces were embedded from the **512px analysis image**, but faces under **48px**
  are discarded as too small to embed. A standing figure's face at 512px is
  ~30–40px, so **every full-length, mid-distance and group photo produced zero
  faces** — which is most of what a wardrobe scan looks at.
- Zero faces meant `.unknown`, and `.unknown` counted as owned. The gate only
  ever produced a verdict on close-up portraits.

**The fix is more pixels, not a lower floor.** A 24px face upscaled to the
model's 112×112 input is a low-information vector, and low-information vectors
against a cosine threshold produce confident matches on *strangers* — the same
failure in a new costume. So when faces are detected but none are embeddable, the
photo is re-read at `identityPixelSize` (1536) and tried once more. That costs a
second decode on a minority of candidates rather than raising the resolution of
the whole scan.

**The deeper lesson, and why diagnostics came first.** Three field tests burned on
a bug that one histogram would have exposed instantly: every face size clustered
below the cutoff. Every scan now writes a `ScanReport` — stage counts, drop
reasons, and the distribution behind every threshold, with the threshold spliced
in as an exact bucket edge so "what would a different value admit?" is a fact
rather than an interpolation. Three tripwires turn shapes into diagnoses: a gate
that rejects everything, a gate that accepts everything, and a gate that never
saw a sample. Nothing in the report describes what the user wears — counts,
durations and scalars only.

Two channels, on purpose. The Xcode MCP's `GetConsoleOutput` reads `Log.scan`
live from a physical device, which is the right tool for "what is it doing right
now". The report is the right tool for "which threshold is wrong", because a
distribution is not something a log stream can usefully carry.

## Field test 3: the fix worked and nothing improved

The identity retry landed and did exactly what it was written to do — photos
positively matched to someone else went from 0 to 131. The user reported no
improvement whatsoever, and the first real report explained why in one number.

**Absence of evidence was being read as consent.** `isOwnerGroup` treated a group
with no readable face as the user's, and the review then pre-selected it. On the
real library that bucket was **165 of 405 candidates — 41%** — so four in ten
candidates bypassed the identity filter entirely and arrived pre-approved. The
retry could not have helped: the junk the user complained about lived almost
entirely in the bucket the retry does not touch.

The rule is now three-valued (`GroupConfidence`): only positive evidence
pre-selects, only positive counter-evidence hides, and "no idea" is shown
unchecked under its own heading. Whenever a classifier's output feeds a default,
check what its *abstention* does — that is where this pipeline has now been bitten
twice.

Two other things the same report settled:

- **The face-match threshold is right.** The cosine distribution is cleanly
  bimodal — an impostor mode below 0.25, a genuine mode peaking near 0.51, and a
  shallow valley between — with 0.363 sitting almost exactly at the density
  minimum. The low ceiling (max 0.608) is the expected signature of 48–130px
  probe faces against a sharp selfie seed, not a defect. Do not re-open it.
- **The person gate is decorative**: 818 of 845 pass, 18 photos rejected out of
  2500. It has been inert since it was written. Tripwires now fire at 5%/95%
  rather than only at 0%/100%, which is what let this hide.

Still unproven, and next: **extraction has never run on real data.** Every field
test so far ended in Discard, so `saved` has been 0 every time — the cutout,
encode and save path is the one stage the product has never actually executed.



Why the photo-library scan works the way it does, what's being improved and in
what order, and where every future capability slots in. Companion to
`ROADMAP.md`. Written after field-testing v1 (which imported everyone's
clothes, camels, and 20 copies of one photoshoot) and three research passes
(Apple on-device APIs, dedup/coverage patterns, and how Tinder/Apple/Google/
Ente ship the same problems).

## The shape: a cheap-to-expensive funnel

Every shipping system studied (Tinder Photo Selector, Apple Photos curation,
Ente, Immich) converges on the same architecture: a cascade where each stage
is more expensive per-photo than the last and sees fewer photos.

```
FETCH      PhotoKit query, newest→oldest, screenshots excluded, bursts
           collapsed (free), scoped window + persisted watermark
TRIAGE     per photo, ~10ms: classify labels + person boxes + utility flag
           → ScanPolicy decides candidacy
IDENTITY   per candidate (Phase B): face embedding vs the user's seed face;
           verified identity propagates within a time cluster
GROUP      time bucket (10-min gaps) + feature-print distance → one group
           per "moment", best member auto-picked (aesthetics + face quality)
REVIEW     grouped grid, one tile per group with "+N similar", user approves
EXTRACT    per approved photo: person-instance cutout → PNG → Piece
           (with capturedAt)
```

Rationale for the big calls:

- **On-device everything.** Free at any scale, the honest version of "photos
  never leave your iPhone", and the differentiator against server-side Google
  Wardrobe. Vision's built-ins cover every stage except face identity.
- **Seed-and-verify, not clustering** (Phase B). Two architectures exist:
  unsupervised face clustering + "label yourself" (Apple/Google/Ente — right
  for general photo managers indexing everyone) and seeded 1:N verification
  (Tinder — right for one target person). Forme has one target person.
  Verification is less code, has no clustering ambiguity, and biometrics can
  be ephemeral.
- **Identity propagates within a moment.** Apple and Google both extend
  person identity via clothing/context *within a time window only* (clothing
  is stable intra-day, not across days). Our dedup time clusters double as
  that window: one face-verified photo marks the whole cluster as "you" —
  which is how faceless mirror selfies survive the identity gate.
- **Review is consent.** The approval grid is simultaneously the quality
  filter, the "whose clothes" filter of last resort, and the privacy story
  (nothing enters the wardrobe unseen).

## Track 1 — algorithmic/quality improvements

### Phase A (pure Apple APIs, no new dependencies)

| # | Change | Fixes |
|---|--------|-------|
| A1 | Wardrobe select-mode + bulk remove / start over | Un-blocks re-testing after junk imports |
| A2 | Fetch hygiene: screenshot exclusion; carry `creationDate` through the pipeline; chronological candidate insertion; `Piece.capturedAt`; scan watermark ("Scanned back to March 2025 · Scan earlier") + incremental re-scan | Arbitrary coverage, shuffled order |
| A3 | Person gate in `ScanPolicy`: person box height ≥ ~25% of frame OR classify confidence ≥ ~0.8 (flat-lay escape hatch) | Camels, TVs, halal carts, crowds |
| A4 | Person-instance cutouts: face/person box center → `instanceAtPoint` → masked image for that instance only (intersect person-class mask when instances fuse) | Falcon/food-bowl/merged-strangers cutouts |
| A5 | Dedup: 10-min time buckets + feature-print distance < ~0.35 within bucket → groups; best-of-group via aesthetics `overallScore` (+ `faceCaptureQuality` tiebreak, boost `.photoDepthEffect`); grouped review UI ("+N" badge, expandable) | 20 near-identical photoshoot pieces |

### Phase B (face identity — the "only me" fix)

| # | Change |
|---|--------|
| B1 | SFace (Apache-2.0) → Core ML conversion; checked-in conversion script; accuracy spot-check harness. Do this spike FIRST — it's the only unproven step |
| B2 | Seed onboarding: embed faces from the Selfies smart album, take the dominant face → one-tap "Is this you?"; fallback: take a selfie (Tinder added this fallback for funnel reasons — keep both) |
| B3 | Verify gate in the pipeline: detect faces → align (landmarks → 112×112) → embed → distance vs seed; propagate verified identity within time clusters |
| B4 | Consent + lifecycle: explicit opt-in screen, embeddings discarded after each scan, only the seed template persisted (deletable in one tap). Never train on user photos — say so |

### Tuning knobs (single source of truth: `ScanPolicy` + named constants)

| Knob | Start | Notes |
|---|---|---|
| Classify confidence | 0.4 | existing |
| Flat-lay confidence floor | 0.8 | tune on real library |
| Min person height fraction | 0.25 | tune on real library |
| Feature-print distance | 0.35 | ShutterSlim-validated; NOT comparable across Vision revisions — store revision with any cached prints |
| Time-cluster gap | 10 min | |
| Face verify distance | ~0.4-equivalent for SFace | calibrate in B1 spike |
| Scan window | 2500 newest | + "scan older" continuation |
| Concurrency | 3 | Tinder profiled 8 as optimal — worth an experiment |

Perf calibration (published numbers): Apple face embedding <4ms on ANE; full
multi-task scene scoring <10ms/photo; feature print ~1.5ms/MP. The decode of
thumbnails, not inference, is the bottleneck. A few-thousand-photo scan stays
"minutes, with visible progress"; re-scans touch only new photos.

## Track 2 — architecture: how this stays easy to change

**Facts vs. policy.** `GarmentDetector.analyze` returns *facts* in
`GarmentObservation` (labels, confidence, person boxes, fingerprint — later:
face matches). A small pure `ScanPolicy` struct turns facts into a decision.
Tuning is editing one value type; testing is constructing observations —
no Vision, no photos.

**Explicit stages, no filter-chain framework.** The stages are shaped too
differently for a uniform `CandidateFilter` protocol chain (per-image async
Vision calls vs. cross-image stateful grouping vs. pure group scoring). The
pipeline is a readable sequence in `ScanPipeline.scan()`; grouping runs at
the store's event drain — the single serialized point. An abstraction with
one implementation is a cost, not an investment.

**Protocol seams only where a second implementation exists.** Every service
has a real and an in-memory implementation (previews and tests run offline):
`PhotoLibraryService`, `GarmentDetector`, `WardrobeService`, plus small
new ones as they earn their place — `ScanHistoryService` (watermark;
UserDefaults-backed) and, in Phase B, `PersonIdentityMatcher` (stub = always
true, so Phase A code never knows Phase B exists).

**Stubs with inert defaults.** Every new observation field or stub knob
defaults to "no effect" (`people` present by default, `fingerprint` nil, ...)
so existing tests never break when a stage is added — only the axis under
test gets scripted.

**Additive, Codable-optional data model.** `capturedAt`, `groupID`, etc. are
optional fields; old on-disk indexes keep decoding. `Piece` already carries
`sourceAssetID` — the hook for dedupe-on-rescan, cloud cleanup, and sync.

**Where the future plugs in** (no restructuring required):

- Cloud cleanup (roadmap "Next"): consumes approved `Piece`s + originals —
  entirely downstream of the scan.
- iOS 27 promptable segmentation: a better implementation *inside*
  `VisionGarmentDetector.cutout` / a tap-to-refine UI; protocol unchanged.
- Supabase sync: behind `WardrobeService`; local store becomes the cache.
- Wardrobe text search (MobileCLIP): a new embedding method on the detector,
  indexed at import time.
- On-device tagging (iOS 27 Foundation Models): post-import enrichment of
  `Piece`, separate from scanning.

## Known tradeoffs and risks (decided or watched)

- **Person gate vs flat-lays**: a hard person requirement kills garment-on-bed
  photos; the OR-branch (very-high-confidence clothing) keeps them. Tunable.
- **Dedup false merges**: two different outfits against the same backdrop in
  one session may group; the expandable group UI is the mitigation (that's
  why grouped review is load-bearing, not cosmetic).
- **Phase A cannot filter a friend's solo portrait** — only Phase B can.
  Set expectations accordingly when testing between phases.
- **PhotoKit predicate flakiness**: subtype-exclusion predicates have a
  documented broken form; use `NOT ((mediaSubtypes & %d) != 0)` and keep an
  in-memory filter fallback. Smoke-test predicates on device early.
- **Simulator Vision failures**: every Vision call site degrades (skip asset
  or fall back to the uncut image); never let the Simulator zero the pipeline.
- **Face embeddings are biometric data**: on-device only, opt-in, ephemeral
  per scan, seed deletable. This is BIPA/GDPR posture as well as brand.
- **Model licensing**: SFace weights are Apache-2.0. InsightFace/EdgeFace
  weights are non-commercial — do not ship them regardless of code license.
