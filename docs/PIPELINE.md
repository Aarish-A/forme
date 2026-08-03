# The wardrobe pipeline

How a photo library becomes a wardrobe, what we measure at each step, and what
we have deliberately not built yet.

This replaces the earlier scan design. That one asked Vision whether a photo
contained clothing, scored itself per photo, and folded six separate facts into
one subjective label. All three were wrong, and the reasons are recorded at the
bottom under *What we got wrong*, because each cost a field test to find.

---

## The one idea

**A wardrobe is a set of physical garments. Photos are evidence, not units.**

Someone's white t-shirt appears in 38 of their photos. That is one wardrobe
entry with 38 pieces of evidence — never 38 entries. The last stage of this
pipeline is entity resolution: many observations collapsing into few objects.
Detection is the easy half.

Two consequences that shape everything downstream:

**The target is one good observation per garment, not every garment in every
photo.** Missing 30 of the 38 white-tee photos costs nothing. Missing the only
photo of the navy blazer loses a garment permanently. This licenses being
aggressively selective, which is a large simplification.

**Photo-level scoring is structurally blind to duplication.** All 38 white-tee
photos score "correct" while the product emits 38 duplicate entries. A metric
that cannot see the primary failure mode will happily report success on a
broken app, and optimising it pushes toward extract-from-everything — the wrong
architecture. Score garments, not photos.

## What "done" means

Ranked, and the ranking is load-bearing:

1. **Effort.** A 60%-complete wardrobe costing four taps is a wardrobe. A
   95%-complete one needing forty corrections is a chore, abandoned halfway,
   yielding nothing.
2. **Precision.** A wrong entry asserts you own something you don't. That reads
   as *this app doesn't know me* — the "more judged, not more capable" failure.
3. **Coverage**, last, and stated out loud. A missing garment is invisible to
   the user unless we pretend to be complete. Ending with "here's what we found,
   add anything we missed" makes incompleteness honest rather than a defect.

---

## The gates

Each stage answers one question and can reject. Ordered so the cheap ones cull
first — and note that **cost here is image decode, not model inference**.
Everything except identity runs off a single 512 px decode.

| # | Question | Signal | Unit | Cost |
|---|---|---|---|---|
| 1 | Is this a photograph? | asset metadata, utility flag | photo | ~0 |
| 2 | Is a person present and big enough? | person detection | photo → person | 512 px decode |
| 3 | Which bodies show an outfit? | body pose joints | person | free (same decode) |
| 4 | Is the image good enough to read? | sharpness, exposure | photo | free (same decode) |
| 5 | **Is that body the owner?** | face detection → embedding | person | **1536 px re-decode** |
| 6 | Where is each garment? | instance mask + pose partition | garment region | ~300 ms |
| 7 | **Is this the same garment as that one?** | feature print + chroma | garment | ~20 ms |
| 8 | What kind of thing is it? | pose geometry | garment | ~0 |

### Why 3 and 4 run before 5

Not priority — decode cost. A face in a full-length photo is small, so identity
needs a re-decode at 1536 px, and that is the single most expensive operation in
the pipeline. Framing and quality ride free on the decode already paid for at
stage 2, and they roughly halve the number of photos that reach stage 5.

Framing never overrules identity. It only decides *which body is worth
identifying*. If a stranger is well framed and the owner is not, stage 5 still
rejects the photo. That is the correct outcome.

### Why the cascade is per person, not per photo

54% of usable photos contain exactly one other person; 17% contain three or
more. "Is the owner in this photo" cannot say *which body* is theirs, and
stage 6 has to cut a garment off a specific person. So stages 2–5 carry a
person identifier, and identity is a property of a body.

### A face is never allowed to create a person

Person detection answers *is anyone here*. Face detection only answers *who*.
Nothing may enter the pipeline on the strength of a face alone.

This is not pedantry about stage ordering. A face detector fires happily on a
book cover, a poster, a portrait on a gallery wall, a face on a television, and
a face printed on someone's t-shirt. None of those are people, all of them can
carry something that looks like a garment, and a depicted face can clear an
identity threshold — at which point a book jacket's clothes are in someone's
wardrobe under their own name.

The guard is the two-sided association below: a face counts only when it sits
inside a detected person rectangle whose pose agrees. A face with no body is a
depiction.

The corpus labels this directly. `pictured, not real` is its own answer in the
labelling tool rather than a flavour of "nobody", because proving the guard
works requires photos where the correct answer is *a face, but no one there*.

### Stage 5, in detail

Face → body association is two-sided: a face box must contain pose head joints,
and the pose must have a face. No nearest-centroid fallback — that is exactly
how a friend's dress enters someone's wardrobe.

Accept as owner only on: face height ≥ 24 px in the working image, capture
quality above floor, best-match distance under threshold, **and** a margin
between best and second-best match. The margin is what stops a sibling.

Absence of evidence is not evidence of ownership. A body with no readable face
is `unknown`, which is a third state — never silently promoted to `owner`.

### Stage 6, honestly

There is no shippable clothes-parsing model and Vision's classifier has no word
for a shirt. So we do not segment garments. We segment the **person**, then
partition that silhouette geometrically:

1. Instance mask seeded at the shoulder–hip midpoint.
2. Normalise by torso length `L = |shoulder-mid → hip-mid|`.
3. Walk the body axis inside the mask, take median Lab colour per row, find the
   strongest colour discontinuity near the hip line. That is the top/bottom seam.
4. Regions = mask ∩ {above seam}, {seam → ankles}, {below ankles}.

Expected accuracy on a single-layer, front-facing, unoccluded torso: the seam
lands correctly about four times in five. It fails on layered outfits (an open
jacket and the shirt beneath merge into one region — the largest single error),
busy prints, and bottoms generally, which are cropped or furniture-occluded in
most real photos.

### Stage 7 — the stage that makes this a wardrobe

Two passes, because they are different problems.

**Within an occasion** (photos under two hours apart): trivial. Same garment,
same person, same camera, same light. Merge on feature print alone.

**Across occasions**: the actual problem, and the reason this stage exists. Two
ideas carry it:

- **The owner's face is a grey card.** Skin reflectance is constant across six
  months; pixels are not. Sampling a cheek patch and colour-correcting the
  garment region against it puts a white tee under tungsten and the same tee in
  daylight in the same place in chroma space. This works *only* because
  identity is already solved — a nice payoff for the gate ordering.
- **Calibrate on the user's own library, not a benchmark.** The within-occasion
  pass yields free positive pairs; two people in one photo yield free negatives.

The cost asymmetry is deliberate and it decides the threshold. Splitting one
shirt into two entries is a shrug and a merge. Fusing two shirts silently
deletes a garment and shows the wrong photo. Tune for precision over recall.

Known-unsolvable: the plain black tee versus the other plain black tee. Nothing
on device separates them. Don't pretend — surface it as one entry seen N times,
with a visible split affordance.

### Stage 8

The region's extent in torso-normalised coordinates *is* the category. Covers
shoulders → top. Below the seam toward the ankles → bottom. Shoulders through
past the hips with no seam → one-piece. Below the ankles → shoes.

Ship the taxonomy we can actually deliver — top / bottom / one-piece / outer /
shoes — and let the user rename. A confidently wrong label is worse than a
broad correct one.

---

## Rendering: V1, V2, V3

Everything above is identical regardless of how the final tile is drawn.
**Rendering is a swappable last stage**, which is why the labelling schema and
the harness do not depend on this decision at all.

### V1 — segment and select *(what we are building)*

With 38 photographs of a garment, you do not need to invent a clean image. You
need to *pick* the cleanest one: largest garment area, most frontal, least
occluded, sharpest, arms clear of the torso, and prefer photos where the owner
is alone.

Render the masked region. Fall back to a padded rectangular crop when mask
confidence is low — **a failed cutout reads as broken in a way a crop does
not.** Never render on transparency or a checkerboard.

Real pixels, no network, no cost, nothing invented.

### V2 — geometric flatten *(next, and cheap)*

Warp the segmented region toward a canonical garment shape using pose keypoints
— a poor-man's ghost mannequin. No ML, no inference cost, no hallucination,
still real pixels. Worth prototyping because it plausibly closes most of the
gap to generation for none of the risk.

### V3 — generative reconstruction *(deferred, and not close)*

The clean product shot. Currently blocked three separate ways, any one of which
is sufficient:

- **Apple's programmatic image API is being withdrawn.** `ImageCreator` — the
  headless generation class — is deprecated and stops working in iOS 27. The
  supported path is a user-driven sheet, not something a batch can call 50 times.
- **The photorealistic model is not on device.** iOS 26 generation of that
  quality runs on Private Cloud Compute, and it is a style generator with no
  conditioning that means "reconstruct this garment faithfully".
- **The research models are licence-blocked.** TryOffDiff is the state of the
  art for precisely this task and is SSPL — unusable commercially without
  open-sourcing the entire app. This mirrors the clothes-parsing situation
  exactly; the whole area is licensed this way.

That leaves a custom server: per-garment cost, a network dependency, and
uploading photographs of the user in their clothes to our infrastructure.

There is also a product argument, which is the stronger one. **A generated
garment is not your garment.** Straighten a collar the user doesn't have,
invent a pocket, and they are looking at clothes they do not own — in an app
whose purpose is making them feel capable rather than second-guessed.

Device reality, for completeness: on-device diffusion needs 8 GB of RAM and a
~2 GB download, so iPhone 15 Pro and newer only. It could not be the default
path even if the licence and API problems vanished.

---

## Ground truth

The schema records **observations, not judgements**. The test for whether a
field belongs: *would the answer change if we moved a threshold?* If yes it is
policy, not truth, and it must be decomposed.

`torso visible: true` survives a policy rewrite. `worth extracting: high` does
not — and since it *is* the policy, measuring the policy against it measures
nothing.

The direct payoff: every gate becomes a pure function over recorded
observations, so it can be re-tuned and re-scored offline in seconds, forever,
without anyone re-labelling anything.

### What is never labelled by hand

Gate 1 is `PHAsset` metadata plus Vision's utility flag. Gate 4 is a measured
scalar — Laplacian variance for sharpness, a histogram for exposure. Neither is
a question to put to a person: the first is free and exact, and a hand label for
"sharp enough" would bake a threshold into the ground truth, which is the
failure this schema exists to prevent.

That leaves three questions a machine cannot answer, and they are the whole of
the labelling tool: **can an outfit be read off anyone here**, **is that person
the owner**, and **which of these are the same physical garment**.

They are asked in that order because the pipeline runs them in that order.
Asking "is this you" about a queue of thirty-pixel strangers is a question with
no useful answer in either direction, so identity only ever sees what visibility
admitted — 242 of 490 photos rather than all of them.

Framing stays human on purpose even though pose measures it. Pose is the thing
under test; letting it generate its own ground truth would score it against
itself.

**The corpus cannot exercise gate 1.** Converting the fixtures to JPEG rewrote
every file's metadata identically — all 490 report `Apple / iPhone 13 Pro` — so
screenshots are indistinguishable from photographs by metadata here. Gate 1 is
verified on device only, and the corpus carries the derived answer rather than a
measurable one. Recorded because a gate that cannot fail in the harness will
look like a gate that works.

### Shape

```
Photo        id, captured, is_photograph, sharpness, exposure, occasion
  └ Person   identity(owner|other|unknown), facing, occlusion, visible_regions
      └ Appearance  garment_id → Registry, coverage
Registry     garment_id, name, category          # the ~50 physical objects
```

Garment identity is a **pointer to a registry row**, never a description. Free
text cannot do this job: "black tee" / "dark tee" / "black t-shirt" splits one
garment three ways and merges two different ones, and consistency across 38
appearances is unverifiable.

### Metrics

| Stage | Metric | Needs a device? |
|---|---|---|
| 2 person | recall / precision at IoU ≥ 0.5 | yes |
| 3–4 usable | recall–precision curve over the gate | **no** — pure function of labels |
| 5 identity | true-positive rate at fixed false-positive rate; body-swap rate | yes |
| 6 segment | mask IoU; fraction of foreign-person pixels | yes |
| 7 cluster | **BCubed** precision / recall | yes |
| 8 category | macro-F1 | yes |
| end-to-end | garment recall; duplicate rate; taps-to-correct | yes |

BCubed for clustering because it is computed per item and averaged, so it
degrades gracefully under this skew (one garment at 38×, most at 1–2×). Pair
counting is swamped by the largest cluster.

### Traps this schema is built to avoid

- **Seeding.** Garment labels collected by correcting machine clusters inherit
  the model's notion of similarity, and it then scores against itself. Guard: a
  holdout grouped from scratch, unseeded, in randomised order.
- **Leakage through near-duplicates.** Split train/test by **occasion**, never
  by photo — photos within an occasion are near-identical.
- **Convenience bias.** Humans label confidently exactly where the task is
  easy. Guard: every metric reported twice, on certain-only and on all, with
  the unsure rate published as a first-class number.
- **Silence reading as success.** A skipped suite and a passing suite look
  identical in a summary. Anything that can't find its corpus says so, loudly.

---

## What we got wrong

Recorded so it isn't rediscovered.

**Asking Vision whether a photo contains clothing.** Its taxonomy has no
identifier for a shirt, trousers, or a sweater. Of 74 clothing labels tried, 49
do not exist; only ~17% of one real wardrobe is nameable. The gate dropped 1,602
of 2,500 photos on that basis while admitting a stranger's formalwear shoot,
because `suit` and `gown` *are* real words. No threshold could have fixed it.

**Embedding faces from a 512 px render and discarding those under 48 px.** Every
full-length photo — exactly the ones that show an outfit — yielded zero faces,
so identity was structurally dead while appearing to run.

**Treating absence of evidence as consent.** A photo with no readable face
counted as the owner's and was pre-selected. 41% of candidates bypassed identity
entirely.

**Running person detection behind an early return from classification**, so
1,602 photos were never checked for a person at all.

**`outfitValue: high|medium|low|none`.** One subjective scalar bundling: is the
torso visible, is the image sharp, is the person occluded, is this a worse
duplicate of the shot beside it. When a photo failed, the label could not say
which. No single signal could ever predict it. And it *was* the policy, so the
harness was measuring the policy against itself.

**Scoring photos.** The deepest one, and the reason for this rewrite.
