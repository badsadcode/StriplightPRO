# Tone methods and fast export

Added in StriplightPRO on top of the original Striplight snapshot.

## Tone methods

The **Method** drop-down in *Gray Image Adjustment* has four new entries after
the five original ones. The original five are unchanged: they produce the same
pixel values as before.

The new methods are *adaptive*: they look at each frame before adjusting it,
so one setting can cope with dark, bright and unevenly exposed frames on the
same roll. They are meant for the frames a single global curve cannot rescue.

| Method | What it does | Use it for |
| --- | --- | --- |
| Auto levels | Stretches each frame so its darkest and brightest content use the full range. | Frames that are evenly too dark or too bright. |
| Local contrast (CLAHE) | Splits the frame into tiles and equalises contrast in each, blending between tiles. | Frames that are dark in one part and bright in another; faint text. |
| Exposure balance | Brightens dark regions and darkens bright regions, using a blurred copy of the frame as the guide. | Mixed exposure where you want a natural look rather than maximum contrast. |
| Background flatten | Estimates the paper brightness across the frame and evens it out to a light background. | Text documents with shading, vignetting or uneven lighting. |

### Strength

The new **Strength** slider (0 to 100, default 50) is active only for the
adaptive methods.

- Auto levels: how much of the darkest and brightest pixels may be clipped
  (0 = none, 100 = 2% at each end).
- Local contrast: the contrast limit (0 = off, 100 = strongest). Higher values
  also bring out more film grain.
- Exposure balance: how strongly shadows are lifted and highlights pulled back
  (0 = off).
- Background flatten: how much of the correction is applied (0 = off,
  100 = fully flattened).

Contrast, Brightness and Gamma keep the *Striplight current* ranges with the
adaptive methods and are applied after the adaptive step, as are the option
check boxes. Strength is stored per roll in the SLF file (`AdjustStrength`).

### Things to know

- Statistics for auto levels come from the central 80% of the frame, so film
  borders and gaps between frames do not decide the result. The stretch is
  limited to about 4x so a blank frame is not turned into noise.
- Local contrast, exposure balance and background flatten also bring the frame
  to full range, so they work on evenly dark or bright frames too.
- Background flatten assumes dark text on light paper. With **Negative**
  ticked it works on the inverted image, so negative film is handled.
- The frame preview window and the export use the same code and give the same
  result at full resolution. The strip view applies adaptive methods to each
  strip preview rather than to each frame, so treat it as a close guide.
- Per-frame overrides keep working: a frame's own contrast, brightness and
  gamma replace the roll's values; the method and strength come from the roll.

## Fast export path

When all of these are true, frames are built on a new 8-bit grayscale path:

- JPEG encoder is **TurboJPEG DLL**,
- **Export grayscale JPEG** is ticked,
- the strip files are grayscale JPEGs.

Otherwise the original path is used, unchanged. A frame also falls back to
the original path by itself if anything goes wrong on the fast path. The
export debug log shows which path each frame took (`grayscale path` or
`gray-fallback`).

What is different on the fast path:

- Strips are decoded straight to 8-bit gray: a quarter of the memory of BGRA.
- All export workers share one cache of decoded strips, so a strip needed by
  several workers is decoded once instead of once per worker. The **Cache**
  setting is the total number of strips kept.
- Crop, rotate and paste happen in one pass, with no intermediate copies.
- Each worker compresses its JPEG at the same time as the others. Only the
  final file write still takes turns. Before, compression itself was done one
  worker at a time.

The output is meant to be identical to the original path for grayscale
strips. `tests/striplight_tests.lpr` checks the lookup tables and the frame
assembly against the original math.

## Code layout

- `uToneAdjust.pas`: all tone math on plain 8-bit buffers. No GUI dependency.
- `uToneBitmap.pas`: applies a tone adjustment to a `TBGRABitmap`.
- `uTurboRaw.pas`: TurboJPEG decode/encode on memory buffers.
- `uFrameGray.pas`: grayscale frame assembly and the shared strip cache.
- `tests/striplight_tests.lpr`: command-line checks, a tone-method tryout tool
  and a benchmark. Build with `fpc -O2 -Fu. tests/striplight_tests.lpr` from
  the repository directory.

To try a method on a grayscale JPEG without opening the application:

```
striplight_tests tone in.jpg out.jpg <method 0..8> [strength]
```
