# Forme roadmap

Working notes on where the product is headed. The mission and design bar live
in `CLAUDE.md`; this file tracks feature sequencing.

## Now — on-device wardrobe onboarding (Phase 1 + 2)

- [x] Piece catalog: local-only storage, wardrobe grid, manual add via photo
      picker with on-device subject cutout.
- [x] Photo-library scan: primer → permission → on-device Vision scan →
      review grid → wardrobe. Nothing leaves the device.

Deliberate MVP simplifications (revisit later):

- A worn outfit becomes one piece (whole-look cutout), not separate garments —
  no on-device per-garment segmentation exists today.
- Scan covers the most recent slice of the library and runs only while the
  flow is open (no background/overnight scanning, no resumable scan cache).
- Category is a one-tap manual pick with a rough auto-suggestion; no rich
  attributes (color, fabric, season).

## Next

- **Cloud cleanup, opt-in (“clean up my catalog”)**: send only user-approved
  images to a generative model (Gemini nano-banana family) for per-garment
  product-style shots + auto-tagging. Keep the original cutout alongside.
  Honest privacy copy: paid API tier, not used for training, retention window
  disclosed. Cost ≈ $0.03–0.13/garment, one-time.
- **Hybrid extraction**: cloud detection boxes → crop → cleanup (real pixels,
  no hallucination) as a middle tier.
- **Supabase sync**: `pieces` table + storage bucket, RLS scoped to
  `auth.uid()`; local store becomes the offline cache.
- **Per-garment splitting on device**: iOS 27 promptable segmentation
  (`GenerateIterativeSegmentationRequest`) seeded from body-pose joints;
  tap-to-split a look into pieces.
- **On-device tagging**: Foundation Models image input (iOS 27) for
  category/color/attributes without the cloud.
- Scan robustness: resumable scan cache keyed by asset id + modification
  date, background/overnight scan (`BGProcessingTaskRequest`), thermal/Low
  Power awareness, limited-library expansion flow.

## Later

- AI try-on: visualize outfits on yourself (the faithful catalog is the input
  this needs — onboarding quality compounds here).
- Add pieces from the web (Zara, Aritzia, H&M product pages / share sheet).
- Outfit planning: plan a week or a specific day.
- Sale alerts for pieces you're watching online.
- Style recommendations.
