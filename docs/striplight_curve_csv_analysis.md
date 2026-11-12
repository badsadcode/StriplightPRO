# Curve CSV Analysis for Striplight

## Source file

Analyzed file:

`curve.csv`

The file contains 16 comma-separated coordinate pairs with no header:

```text
0,0
273,429
546,764
819,1071
1092,1361
1365,1639
1638,1908
1911,2170
2184,2425
2457,2675
2730,2921
3003,3162
3276,3423
3549,3635
3822,3866
4095,4095
```

---

# 1. Main finding

The file appears to describe a **16-point tone/gamma curve operating in a 12-bit numerical domain**.

The input and output ranges are:

```text
0 .. 4095
```

This is significant because:

```text
2^12 - 1 = 4095
```

Therefore the curve is very likely represented internally using **12-bit intensity values**.

This does not necessarily mean that the scanner's sensor, image file, or complete processing pipeline is only 12-bit. It means that this particular curve representation uses a 0–4095 coordinate space.

---

# 2. Number and spacing of points

There are exactly **16 coordinate pairs**.

The X coordinates are:

```text
0
273
546
819
1092
1365
1638
1911
2184
2457
2730
3003
3276
3549
3822
4095
```

The spacing is constant:

```text
273
```

And:

```text
4095 / 15 = 273
```

This means the 16 points cover the complete 12-bit range at 15 equal intervals.

The X position can therefore be described as:

```text
x[n] = n * 273
```

for:

```text
n = 0 .. 15
```

Normalized to the range 0–1, these positions are:

```text
0/15
1/15
2/15
3/15
...
15/15
```

or approximately:

```text
0.0000
0.0667
0.1333
0.2000
0.2667
0.3333
0.4000
0.4667
0.5333
0.6000
0.6667
0.7333
0.8000
0.8667
0.9333
1.0000
```

This strongly suggests that the original software has a curve representation based on **16 fixed X positions with editable Y values**.

---

# 3. Gamma relationship

Almost all Y values match a simple gamma curve extremely closely.

The apparent formula is:

```text
output = 4095 * (input / 4095)^(5/6)
```

Since:

```text
5/6 = 0.833333...
```

this is equivalent to:

```text
output = 4095 * (input / 4095)^0.833333...
```

It can also be written as:

```text
output = 4095 * (input / 4095)^(1 / 1.2)
```

Therefore the curve appears to correspond to:

```text
Gamma = 1.2
```

assuming the software uses the common inverse-gamma convention.

---

# 4. Comparison with an ideal Gamma 1.2 curve

The values produced by the mathematical Gamma 1.2 curve are almost identical to the values in the CSV.

| X | CSV Y | Gamma 1.2 prediction | Difference |
|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 |
| 273 | 429 | ~428.7 | ~+0.3 |
| 546 | 764 | ~763.9 | ~+0.1 |
| 819 | 1071 | ~1071.0 | ~0 |
| 1092 | 1361 | ~1361.1 | ~-0.1 |
| 1365 | 1639 | ~1639.3 | ~-0.3 |
| 1638 | 1908 | ~1908.3 | ~-0.3 |
| 1911 | 2170 | ~2169.8 | ~+0.2 |
| 2184 | 2425 | ~2425.2 | ~-0.2 |
| 2457 | 2675 | ~2675.3 | ~-0.3 |
| 2730 | 2921 | ~2920.9 | ~+0.1 |
| 3003 | 3162 | ~3162.3 | ~-0.3 |
| 3276 | 3423 | **~3400** | **~+23** |
| 3549 | 3635 | ~3634.7 | ~+0.3 |
| 3822 | 3866 | ~3866.2 | ~-0.2 |
| 4095 | 4095 | 4095 | 0 |

Except for one point, the differences are effectively what would be expected from ordinary rounding to integer values.

This is extremely strong evidence that the original curve was generated from a **Gamma 1.2 mathematical function**.

---

# 5. The anomalous point

The unusual coordinate is:

```text
3276,3423
```

For a mathematically clean Gamma 1.2 curve, this point should be approximately:

```text
3276,3400
```

The deviation is therefore approximately:

```text
+23
```

on a full vertical scale of:

```text
0 .. 4095
```

That corresponds to only approximately:

```text
23 / 4095 ≈ 0.0056
```

or about:

```text
0.56%
```

of the full range.

This is a very small visual displacement in a graphical curve editor.

---

# 6. Most likely explanation for the anomaly

A plausible explanation is that the operator accidentally moved that control point and then manually attempted to restore it.

This explanation fits the data particularly well.

If the intended curve were generated automatically as Gamma 1.2, every other intermediate point is essentially mathematically exact after rounding.

Only one point differs meaningfully.

That is much more consistent with:

1. A Gamma 1.2 curve being generated.
2. One control point being accidentally dragged.
3. The operator visually moving it back near its original position.
4. The point ending at 3423 instead of the mathematically correct value of approximately 3400.

The error is small enough that a person dragging a point with a mouse could easily consider it visually restored.

This also provides indirect evidence that the displayed curve points in the original application may be **real editable control points**, rather than merely visualization markers.

---

# 7. Local shape around the anomalous point

The anomaly can also be seen by looking at the differences between adjacent Y values.

Around the relevant area:

```text
2730 -> 2921
3003 -> 3162
3276 -> 3423
3549 -> 3635
3822 -> 3866
```

The local Y increments are approximately:

```text
+241
+261
+212
+231
```

The sudden `+261` followed by `+212` produces a small local irregularity.

If the anomalous point were changed from:

```text
3423
```

to approximately:

```text
3400
```

the increments would become much smoother:

```text
+241
+238
+235
+231
```

This again supports the hypothesis that 3423 is a manually displaced point rather than part of the intended mathematical function.

---

# 8. What the curve does visually

All intermediate output values are higher than their corresponding input values.

Examples:

```text
273  -> 429
546  -> 764
819  -> 1071
1365 -> 1639
2730 -> 2921
```

The endpoints remain fixed:

```text
0    -> 0
4095 -> 4095
```

Therefore the curve raises shadows and midtones while preserving absolute black and white.

This is characteristic of a gamma brightening operation.

The relative effect is strongest in darker values and gradually decreases toward white.

For example:

```text
Input ~6.7%   -> Output ~10.5%
Input ~13.3%  -> Output ~18.7%
Input 20.0%   -> Output ~26.2%
Input 93.3%   -> Output ~94.4%
```

---

# 9. Likely internal representation

A reasonable model of the original software is:

```text
Curve
    Input range:       0 .. 4095
    Output range:      0 .. 4095
    Number of points:  16
    X positions:       fixed
    Y positions:       editable
```

The fixed X coordinates would be:

```text
x[n] = n * 273
```

with:

```text
n = 0 .. 15
```

The corresponding curve could therefore internally be stored only as the 16 Y values:

```text
[
    0,
    429,
    764,
    1071,
    1361,
    1639,
    1908,
    2170,
    2425,
    2675,
    2921,
    3162,
    3423,
    3635,
    3866,
    4095
]
```

The X values would be implicit because they are always equally spaced.

However, for maximum compatibility and future flexibility, Striplight may still want to preserve complete `(X,Y)` pairs when importing or exporting.

---

# 10. CSV format

The observed format is extremely simple.

Each line contains:

```text
X,Y
```

There is:

- no header
- no metadata
- no explicit gamma value
- no curve name
- no version number
- no channel identifier
- no comments

Example:

```text
0,0
273,429
...
4095,4095
```

This suggests that the file stores the **resulting control points**, not the mathematical formula used to generate them.

That distinction is important.

A Gamma 1.2 tool may have generated these points originally, but the saved file apparently represents the points themselves.

---

# 11. Implication for Striplight's data model

For compatibility and flexibility, Striplight should probably treat the **curve itself** as the primary object.

Gamma should be treated as one possible way to generate a curve.

Recommended conceptual design:

```text
Curve
    points[16]
```

with tools such as:

```text
Generate Linear Curve
Generate Gamma Curve
Edit Point
Reset Point
Reset Curve
Import Curve
Export Curve
```

A Gamma 1.2 operation would calculate:

```text
for i = 0 .. 15:
    x_normalized = i / 15
    y_normalized = x_normalized^(1 / 1.2)
    y = round(y_normalized * 4095)
```

The ideal generated Y values would be approximately:

```text
0
429
764
1071
1361
1639
1908
2170
2425
2675
2921
3162
3400
3635
3866
4095
```

The imported curve differs meaningfully only at the `3276` point.

---

# 12. Recommended behavior when editing a generated gamma curve

A useful Striplight behavior would be:

```text
Gamma: 1.20
```

when the curve exactly matches a generated gamma function.

If the user manually moves a control point, Striplight could change the display to:

```text
Gamma: Custom
```

or:

```text
Base Gamma: 1.20
Custom adjustments
```

This would support both mathematically generated curves and manual scanner-operator corrections.

It also matches the likely history of the analyzed file.

---

# 13. Automatic gamma detection

Striplight could attempt to detect whether an imported curve resembles a standard gamma curve.

Conceptually:

1. Normalize X and Y to 0–1.
2. Fit the curve to:

```text
y = x^(1/gamma)
```

3. Calculate the best-fitting gamma.
4. Measure each point's deviation from the fitted curve.

For this file, the software would probably detect something close to:

```text
Detected Gamma: ~1.20
```

and could additionally report:

```text
1 control point differs from the fitted curve
```

For the anomalous point:

```text
X:        3276
Expected: ~3400
Actual:   3423
Offset:   +23
```

This could be useful both for diagnostics and for importing old scanner curves.

---

# 14. Interpolation

The CSV contains only 16 points, while the curve domain contains 4096 possible integer input values.

Therefore the original software must either:

- interpolate between control points, or
- internally generate a larger LUT from the 16 control points.

The simplest and most likely method is linear interpolation.

For two adjacent control points:

```text
(x0, y0)
(x1, y1)
```

and an input `x` between them:

```text
t = (x - x0) / (x1 - x0)
```

then:

```text
y = y0 + t * (y1 - y0)
```

Because the X spacing is always 273:

```text
segment = floor(x / 273)
```

and then interpolation occurs between that point and the next one.

For example:

```text
x0 = segment * 273
x1 = (segment + 1) * 273

t = (x - x0) / 273
```

The corresponding output becomes:

```text
y = y0 + t * (y1 - y0)
```

**Important:** linear interpolation is currently a hypothesis, not something proven by this file alone.

---

# 15. 4096-entry LUT

Striplight could convert the 16-point control curve into a full lookup table:

```text
LUT[0 .. 4095]
```

Once generated, processing is extremely inexpensive:

```text
output = LUT[input]
```

This approach has several advantages:

- very fast image processing
- deterministic results
- simple implementation
- easy preview generation
- easy GPU implementation later
- exact preservation of arbitrary custom curves

The LUT would be regenerated only when the curve changes.

---

# 16. Source bit depth versus curve bit depth

The curve's 0–4095 domain should not automatically be assumed to be the bit depth of every source image.

A source image could potentially be:

- 8-bit
- 12-bit
- 16-bit
- floating point

Striplight can normalize any input format into the curve domain.

For example, an 8-bit value could conceptually map as:

```text
curveInput = pixel8 * 4095 / 255
```

A 16-bit value could map as:

```text
curveInput = pixel16 * 4095 / 65535
```

For best quality, it would be preferable to preserve fractional precision during this mapping and interpolation rather than prematurely rounding everything to 12-bit integers.

---

# 17. Endpoints

The observed curve fixes:

```text
0 -> 0
```

and:

```text
4095 -> 4095
```

It is not yet known whether the original application requires these endpoints to stay fixed or merely happened to leave them fixed for this curve.

This should be tested with the original software if possible.

Useful experiment:

1. Try dragging the first point.
2. Try dragging the last point.
3. Export the curve.
4. Examine whether X or Y values at the endpoints can change.

If they cannot change, Striplight should probably reproduce that restriction when operating in compatibility mode.

---

# 18. Fixed X versus movable X

The current file strongly suggests fixed X positions because all 16 X values are exactly equally spaced.

However, one file alone cannot prove that the software prohibits horizontal movement.

A useful experiment would be to deliberately drag a middle control point horizontally if the UI permits it, export the curve, and inspect the resulting CSV.

Possible outcomes:

## Fixed X

If the exported X remains:

```text
0
273
546
...
4095
```

then the original software uses fixed X positions.

## Movable X

If one X value changes, then the file format supports arbitrary two-dimensional control points.

At present, **fixed X is the more likely interpretation**.

---

# 19. Linear versus smooth interpolation

The current file does not reveal whether the original software connects the control points using:

- straight-line interpolation
- cubic interpolation
- spline interpolation
- another smoothing method

Because the points themselves closely follow a gamma function, a visually smooth display could be produced by several methods.

This is one of the most important remaining unknowns.

A good test curve would deliberately alternate points dramatically, for example:

```text
low
high
low
high
```

Then inspect either:

- the visual curve drawn by the original software, or
- the processed image/output values.

A strongly artificial curve would make the interpolation method much easier to identify.

---

# 20. Suggested reverse-engineering experiments

To understand the original system more completely, export several controlled curves.

## Experiment A: Linear/reset curve

Reset the curve to completely linear and export it.

Expected values may be:

```text
0,0
273,273
546,546
...
4095,4095
```

This would confirm the coordinate model.

## Experiment B: Known Gamma values

Export known settings such as:

```text
Gamma 0.8
Gamma 1.0
Gamma 1.2
Gamma 1.5
Gamma 2.0
```

Compare the output against:

```text
y = x^(1/gamma)
```

This would establish the exact gamma convention used by the software.

## Experiment C: Move one point

Start from a known gamma curve and deliberately move exactly one point.

Export before and after.

This can reveal:

- whether X is fixed
- Y coordinate behavior
- rounding behavior
- whether moving one point modifies neighboring points

## Experiment D: Move an endpoint

Try changing the first or last point.

This determines whether black and white endpoints are locked.

## Experiment E: Extreme alternating curve

Create a deliberately jagged curve.

This helps determine the interpolation method.

## Experiment F: Save and reload

Create a curve, save it, restart the software, reload it, then export again.

If the values remain byte-for-byte identical, the CSV is probably the authoritative stored representation.

If they change slightly, the application may be reconstructing or smoothing the curve internally.

---

# 21. Potential Striplight compatibility mode

Striplight could eventually support a mode specifically compatible with the original scanner software.

Possible behavior:

```text
Original Curve Compatibility
----------------------------
Domain:        0 .. 4095
Points:        16
X spacing:     273
Interpolation: configurable once identified
CSV format:    X,Y
```

This would allow existing curve files to be exchanged between Striplight and the original application.

---

# 22. Recommended Striplight curve architecture

A practical internal structure could be:

```text
Curve {
    points
    interpolationMode
    metadata
}
```

For original-software compatibility:

```text
points = 16
domainMin = 0
domainMax = 4095
```

Each point could internally use floating-point values even if import/export uses integers.

For example:

```text
Point {
    x: float
    y: float
}
```

The compatibility exporter would quantize values back into:

```text
0 .. 4095
```

integers.

This allows Striplight's internal processing to remain high precision while preserving exact compatibility with legacy files.

---

# 23. Preserve imported values exactly

An important design recommendation is to preserve the imported integer coordinates exactly.

For example, Striplight should not silently decide:

```text
3276,3423
```

"should really be"

```text
3276,3400
```

and modify it.

Even if the point is probably an accidental manual deviation, imported data should remain unchanged unless the user explicitly asks Striplight to normalize or regenerate the curve.

A useful option could be:

```text
Fit to nearest gamma curve
```

which could show:

```text
Best fit: Gamma 1.20
Maximum deviation: 23
```

and let the user choose whether to replace the imported curve.

---

# 24. Possible UI design

A Striplight curve editor could show:

```text
Curve
────────────────────────

Gamma: 1.20

[ graphical editor ]

Input:  3276
Output: 3423

[Reset Point]
[Reset Curve]
```

If the curve is edited manually:

```text
Gamma: Custom
```

or:

```text
Gamma base: 1.20
Edited points: 1
```

For an imported curve, Striplight could optionally display:

```text
Imported curve

Best mathematical fit:
Gamma 1.20

Custom deviations:
1 point
```

---

# 25. Why storing points is better than storing only gamma

The file demonstrates why the program should not use a single gamma number as its fundamental curve representation.

A single gamma value cannot represent:

- manually moved control points
- S-curves
- custom shadow corrections
- custom highlight corrections
- historical scanner calibration curves
- unusual nonlinear transforms

A 16-point curve can represent all of these.

Therefore:

```text
Curve points = primary data
Gamma = curve generator
```

is the safer design.

---

# 26. Likely processing model

A provisional model of the original software is:

```text
Source image intensity
        |
        v
Normalize / represent in 12-bit curve space
        |
        v
16-point tone curve
        |
        v
Interpolation / LUT generation
        |
        v
4096-value transfer function
        |
        v
Corrected output intensity
```

The exact interpolation method remains to be established.

---

# 27. Confidence levels

## Very high confidence

- Curve numerical domain is 0–4095.
- 4095 corresponds naturally to a 12-bit range.
- File contains 16 points.
- X points are uniformly spaced by exactly 273.
- Most points match Gamma 1.2 extremely closely.
- The point `(3276,3423)` is a clear outlier relative to the Gamma 1.2 model.

## High confidence

- Gamma 1.2 generated the original intended curve.
- The anomalous point was manually altered or otherwise modified after generation.
- The CSV stores curve points rather than merely storing a gamma parameter.

## Moderate confidence

- X positions are fixed in the original editor.
- Y positions are manually editable.
- The program interpolates between the 16 values.

## Unknown

- Exact interpolation method.
- Whether X coordinates can be moved.
- Whether endpoints are locked.
- Whether processing internally remains 12-bit or uses higher precision.
- Whether curve calculation occurs before or after other scanner corrections.
- Whether separate curves exist for different channels.
- Whether the curve is applied in linear-light or gamma-encoded image space.
- Exact rounding/truncation rules.
- Whether this CSV format changes between software versions.

---

# 28. Key conclusion for Striplight

The strongest implementation model supported by this file is:

```text
12-bit curve domain
0 .. 4095

16 control points

X positions:
0, 273, 546, ..., 4095

Y positions:
user-editable / stored in CSV

Gamma is used to generate control points,
but the saved curve itself is represented by point coordinates.
```

The analyzed file appears to be essentially a **Gamma 1.2 curve with one manually displaced control point**.

This makes the file particularly valuable because it reveals both:

1. the underlying mathematical curve generation, and
2. probable manual control-point editing behavior.

For Striplight, the recommended approach is therefore:

```text
Use a 16-point curve as the canonical representation.

Support Gamma as a generator.

Preserve arbitrary imported values exactly.

Generate a high-resolution LUT from those control points.

Add original CSV import/export compatibility.

Determine interpolation behavior through additional controlled exports.
```

---

# 29. Best next sample files to collect

The most useful additional exports from the original software would be:

1. Completely reset / linear curve.
2. Fresh Gamma 1.2 curve without touching any points.
3. Gamma 1.0.
4. Gamma 2.0.
5. One curve where exactly one point has deliberately been moved vertically.
6. One curve where a point is deliberately moved horizontally, if possible.
7. A deliberately extreme zig-zag curve.
8. A curve with altered endpoints, if allowed.

With those files, it should be possible to reconstruct the curve system with much greater certainty.

---

## Summary

This small CSV gives a surprisingly strong fingerprint of the original curve system:

```text
Range:       0–4095
Bit-domain:  12-bit
Points:      16
X spacing:   273
Likely base: Gamma 1.2
Outliers:    1
Outlier:     3276,3423
Expected:    ~3276,3400
```

The anomaly is highly compatible with a user accidentally moving a graphical control point and subsequently restoring it approximately by hand.

For Striplight, this is enough information to begin implementing a compatible curve model without depending on the original software's internal code.
