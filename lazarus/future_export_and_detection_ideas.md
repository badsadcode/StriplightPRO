# Future Export And Detection Ideas

This note captures ideas discussed while improving Striplight. It is meant as a reference for future work, not a current implementation plan.

## Detection Reality

Microfilm is inconsistent in real life:

- Some cameras left clear gaps between frames.
- Some cameras left very narrow gaps.
- Some broken or badly adjusted cameras left no usable gaps.
- Gap size can vary across a roll.
- Exposure and lighting can vary.
- Book spine shadows can be dark enough to look like frame gaps.
- Blank cards, title cards, handwriting, typed pages, and dense documents can all behave differently.

The detection problem is therefore not simply "find frames." It is "find frames through messy historical camera behavior."

## Detection Improvement Ideas

### Detection Preview Overlays

Show what the detector is seeing before creating frames:

- Threshold mask.
- Candidate content runs.
- Ignored blobs.
- Candidate gaps.
- Merge candidates.
- Low-confidence regions.

This would make threshold tuning less blind.

### Gap Confidence Instead Of Hard Gap Detection

A true inter-frame gap usually spans most of the film width and behaves like a boundary. A book spine shadow may be dark, but it usually sits inside a page.

Possible confidence signals:

- How far the dark band spans across the frame width.
- Whether it touches or crosses expected frame edges.
- Whether the dark band is straight and continuous.
- Whether page-like content exists on both sides.
- Whether nearby frames follow the same rhythm.

### No-Gap Camera Mode

Some rolls may need a mode that assumes frames are adjacent or nearly adjacent. In this mode, detection would rely more on expected frame size/rhythm than visible black gaps.

Useful when a camera was broken or advanced film without leaving clear spacing.

### Per-Roll Camera Profiles

Possible presets:

- Normal gaps.
- Narrow gaps.
- No gaps / continuous camera.
- Book pages with spine shadows.
- Mixed exposure / weak contrast.

Each profile could adjust detection threshold, merge behavior, gap expectations, and split suggestions.

### Spine-Shadow Rejection

For book scans, the detector could avoid treating internal spine shadows as frame boundaries when the dark region behaves like part of a page rather than a full frame gap.

### Oversized Frame Assistant

When a selected frame is much larger than the median frame height, the app could:

- Estimate likely split counts from median frame height.
- Show preview cuts automatically.
- Offer quick split options like 2, 3, 4, 5, 6, 8, 10.
- Classify likely cause:
  - Missed narrow gaps.
  - No-gap camera sequence.
  - Book spine shadow confused detection.
  - Blank or dark exposure area.

This would make common detection failures cheap to correct.

### Manual Corrections As Hints

If the user manually fixes frames in a region, nearby frames may need similar treatment. Future tools could apply a correction pattern forward/backward across nearby frames.

## Full-Quality Frame Preview

Current double-click preview uses preview JPGs. That is fast, but not export-quality.

Future double-click preview should:

- Try full strip images first.
- Render the selected frame from full-resolution strips when available.
- Fall back to preview JPGs when full strip files are missing.
- Show a status such as `Full quality preview` or `Preview quality fallback`.
- Stay responsive, because full-resolution stitching may be heavier.

This should be built before final export, because export will use the same full-resolution frame assembly logic.

## Export Pipeline Ideas

Export should be non-destructive:

- Original strip files remain untouched.
- Export writes new image files.
- Preview and export should use the same rendering path.
- What the user sees in full-quality preview should match what export produces.

Suggested order:

1. Full-quality preview from strip files.
2. Export-preview adjustments on full-quality preview.
3. Global export brightness/contrast/gamma.
4. Per-frame adjustment overrides.
5. Export files using the same rendering and adjustment code as preview.

## Adjustment Layers

Keep three separate concepts:

### Preview Adjustments

Temporary, non-destructive controls used to help viewing and detection.

These are the current preview brightness/contrast/gamma controls and should remain separate.

### Export Adjustments

Persistent settings applied only when exporting files.

These settings should be saved in the project.

### Per-Frame Overrides

Most frames use the global export adjustment, but individual frames can override brightness/contrast/gamma when needed.

Useful for frames that are darker, overexposed, or otherwise different from the rest of the roll.

Possible controls:

- Global export brightness.
- Global export contrast.
- Global export gamma.
- Apply to all frames.
- Enable selected frame override.
- Clear selected override.
- Clear all overrides.
- Copy adjustment from selected frame.
- Paste adjustment to selected frames.

## Tone Adjustment Methods

Brightness, contrast, and gamma are not universal operations. Different applications calculate them differently.

The scanner software may use a vendor library, tone curve, LUT, dynamic range expansion, shadow recovery, or another proprietary method. This may explain why it can reveal information that XnView or Photoshop cannot recover in the same way.

Future UI idea:

`Tone method: [Standard RGB ▼]`

Then the same three sliders:

- Brightness.
- Contrast.
- Gamma.

The sliders stay familiar, but the math changes depending on the selected tone method.

Possible methods:

### Standard RGB

Simple per-pixel brightness/contrast/gamma. Predictable and fast.

### Document Recovery

Gently lifts shadows while protecting bright paper areas. Useful for underexposed text.

### High Contrast Text

Pushes text/background separation harder. Useful for faint writing, but risky for photos or fragile tonal detail.

### Soft Contrast

More conservative contrast curve. Useful for overexposed or fragile faint images.

### Shadow Lift

Targets dark areas more than bright areas. Useful when content is buried in dark scans.

### Highlight Recovery

Avoids blowing out bright pages/cards. Useful for overexposed frames.

### Scanner-Like

A tuned curve intended to mimic the original scanner app as closely as possible by eye.

## Recommended First Tone Methods

Start with a small set:

1. Standard RGB.
2. Document Recovery.
3. High Contrast Text.

Then tune or add more methods after testing against difficult real rolls.

## Key Principle

Preview and export must use exactly the same adjustment method and math. Otherwise the user cannot trust that the exported files will match what they approved in the preview.
