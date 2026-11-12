unit uToneAdjust;

{ Tone adjustment for Striplight.

  One place for all brightness / contrast / gamma math, shared by the strip
  view, the frame preview window and the export workers, so that what is
  previewed is what gets exported.

  Two families of methods:

  * Classic methods (0..4) are a single 256-entry lookup table. Their math is
    unchanged from the original Striplight code.

  * Adaptive methods (5..8) look at the image itself before the lookup table
    is applied. They exist for scans that a single global curve cannot fix:
    frames that are underexposed, overexposed, or both at once.

  This unit has no LCL or BGRABitmap dependency: it works on plain 8-bit
  grayscale buffers. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

const
  TONE_STRIPLIGHT        = 0;  // Striplight current
  TONE_QUANTUM           = 1;  // Quantum-like
  TONE_CURVE             = 2;  // Original curve
  TONE_CURVE_GAMMA12     = 3;  // Gamma 1.2 curve
  TONE_CURVE_QUANTUM     = 4;  // Original curve + Quantum sliders
  TONE_AUTO_LEVELS       = 5;  // Per-frame black/white point stretch
  TONE_CLAHE             = 6;  // Adaptive local contrast
  TONE_LOCAL_EXPOSURE    = 7;  // Lift dark regions, pull back bright regions
  TONE_BACKGROUND_FLATTEN = 8; // Even out the paper/background brightness
  TONE_METHOD_COUNT      = 9;

  TONE_FLAG_SHADOW_LIFT        = 1;
  TONE_FLAG_HIGHLIGHT_RECOVERY = 2;
  TONE_FLAG_S_CURVE            = 4;
  TONE_FLAG_DOCUMENT_RESCUE    = 8;
  TONE_FLAG_SOFT_CONTRAST      = 16;

  TONE_STRENGTH_MIN     = 0;
  TONE_STRENGTH_MAX     = 100;
  TONE_STRENGTH_DEFAULT = 50;

type
  TToneLUT = array[0..255] of Byte;

{ Display name used in the method drop-down. }
function ToneMethodName(Method: Integer): String;

{ True for methods that analyse the image (5..8). }
function ToneMethodIsAdaptive(Method: Integer): Boolean;

{ True for methods whose sliders use the Quantum ranges
  (contrast -128..255 neutral 64, brightness -128..127, gamma -255..255). }
function ToneMethodUsesQuantumRanges(Method: Integer): Boolean;

{ Lookup table for a classic method. For adaptive methods pass
  TONE_STRIPLIGHT: their sliders use the Striplight ranges and are applied
  after the adaptive step. }
procedure BuildToneLUT(Method, Flags, Contrast, Brightness, Gamma: Integer;
  out LUT: TToneLUT);

{ True when the whole adjustment would leave the image unchanged. }
function ToneIsNoOp(Method, Flags, Contrast, Brightness, Gamma,
  Strength: Integer): Boolean;

procedure ApplyLUTGray(Data: PByte; Width, Height, Stride: Integer;
  const LUT: TToneLUT);

{ Runs only the image-dependent step of an adaptive method. InvertedPolarity
  tells the method that the image is still a negative at this point (light
  text on a dark background), which matters for background flattening. }
procedure ApplyAdaptiveGray(Data: PByte; Width, Height, Stride: Integer;
  Method, Strength: Integer; InvertedPolarity: Boolean);

{ Complete adjustment of an 8-bit grayscale buffer, in place. }
procedure ApplyToneGray(Data: PByte; Width, Height, Stride: Integer;
  Method, Flags, Contrast, Brightness, Gamma, Strength: Integer;
  InvertedPolarity: Boolean);

implementation

const
  NORMALISE_CLIP = 5;   // auto-levels strength used inside the local methods

type
  TIntArray = array of Integer;

  { Low-resolution map of a per-region value, stored as 8.8 fixed point,
    sampled back at full resolution with bilinear interpolation. }
  TLowResMap = record
    W, H: Integer;        // size in cells
    Cell: Integer;        // cell size in pixels
    V: TIntArray;         // W*H values, 0..255*256
    XIdx: TIntArray;      // per image column: left cell index
    XWgt: TIntArray;      // per image column: weight of right cell, 0..256
    RowTmp: TIntArray;    // W vertically interpolated values
  end;

function ToneMethodName(Method: Integer): String;
begin
  case Method of
    TONE_STRIPLIGHT:         Result := 'Striplight current';
    TONE_QUANTUM:            Result := 'Quantum-like';
    TONE_CURVE:              Result := 'Original curve';
    TONE_CURVE_GAMMA12:      Result := 'Gamma 1.2 curve';
    TONE_CURVE_QUANTUM:      Result := 'Original curve + Quantum sliders';
    TONE_AUTO_LEVELS:        Result := 'Auto levels';
    TONE_CLAHE:              Result := 'Local contrast (CLAHE)';
    TONE_LOCAL_EXPOSURE:     Result := 'Exposure balance';
    TONE_BACKGROUND_FLATTEN: Result := 'Background flatten';
  else
    Result := 'Method ' + IntToStr(Method);
  end;
end;

function ToneMethodIsAdaptive(Method: Integer): Boolean;
begin
  Result := (Method >= TONE_AUTO_LEVELS) and (Method < TONE_METHOD_COUNT);
end;

function ToneMethodUsesQuantumRanges(Method: Integer): Boolean;
begin
  Result := (Method = TONE_QUANTUM) or (Method = TONE_CURVE_QUANTUM);
end;

function ClampByte(Value: Integer): Byte; inline;
begin
  if Value < 0 then Result := 0
  else if Value > 255 then Result := 255
  else Result := Value;
end;

{ ---------- Classic lookup-table methods ---------- }

procedure BuildToneLUT(Method, Flags, Contrast, Brightness, Gamma: Integer;
  out LUT: TToneLUT);
const
  CURVE_POINT_COUNT = 16;
  CURVE_IN: array[0..CURVE_POINT_COUNT - 1] of Integer =
    (0, 273, 546, 819, 1092, 1365, 1638, 1911,
     2184, 2457, 2730, 3003, 3276, 3549, 3822, 4095);
  CURVE_OUT: array[0..CURVE_POINT_COUNT - 1] of Integer =
    (0, 429, 764, 1071, 1361, 1639, 1908, 2170,
     2425, 2675, 2921, 3162, 3423, 3635, 3866, 4095);
  CURVE_GAMMA12_OUT: array[0..CURVE_POINT_COUNT - 1] of Integer =
    (0, 429, 764, 1071, 1361, 1639, 1908, 2170,
     2425, 2675, 2921, 3162, 3400, 3635, 3866, 4095);
var
  X: Integer;

  function AdjustChannel(Value: Integer): Byte;
  var
    V, C, G: Double;
    In12, Out12, I: Integer;
  begin
    V := Value / 255.0;
    if Method in [TONE_CURVE, TONE_CURVE_GAMMA12, TONE_CURVE_QUANTUM] then
    begin
      In12 := Round(V * 4095.0);
      if Method = TONE_CURVE_GAMMA12 then
        Out12 := CURVE_GAMMA12_OUT[CURVE_POINT_COUNT - 1]
      else
        Out12 := CURVE_OUT[CURVE_POINT_COUNT - 1];
      for I := 0 to CURVE_POINT_COUNT - 2 do
        if In12 <= CURVE_IN[I + 1] then
        begin
          if Method = TONE_CURVE_GAMMA12 then
            Out12 := CURVE_GAMMA12_OUT[I] +
              Round((Int64(In12 - CURVE_IN[I]) *
                    (CURVE_GAMMA12_OUT[I + 1] - CURVE_GAMMA12_OUT[I])) /
                    (CURVE_IN[I + 1] - CURVE_IN[I]))
          else
            Out12 := CURVE_OUT[I] +
              Round((Int64(In12 - CURVE_IN[I]) *
                    (CURVE_OUT[I + 1] - CURVE_OUT[I])) /
                    (CURVE_IN[I + 1] - CURVE_IN[I]));
          Break;
        end;
      V := Out12 / 4095.0;
    end;

    if Method in [TONE_QUANTUM, TONE_CURVE_QUANTUM] then
    begin
      G := Power(2.0, -Gamma / 255.0);
      if G <= 0.01 then G := 1.0;
      V := Power(V, 1.0 / G);
      C := Power(2.0, (Contrast - 64) / 128.0);
      V := ((V - 0.5) * C) + 0.5;
      V := V - (Brightness / 510.0);
    end
    else
    begin
      G := Gamma / 100.0;
      if G <= 0.01 then G := 1.0;
      V := Power(V, 1.0 / G);
      C := (100.0 + Contrast) / 100.0;
      V := ((V - 0.5) * C) + 0.5;
      V := V + (Brightness / 100.0);
    end;

    if (Flags and TONE_FLAG_SHADOW_LIFT) <> 0 then
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.45);
    if (Flags and TONE_FLAG_HIGHLIGHT_RECOVERY) <> 0 then
      V := V / (V + (1.0 - V) * 1.20);
    if (Flags and TONE_FLAG_S_CURVE) <> 0 then
      V := V * V * (3.0 - 2.0 * V);
    if (Flags and TONE_FLAG_DOCUMENT_RESCUE) <> 0 then
    begin
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.35);
      if V > 0.70 then
        V := 0.70 + (V - 0.70) * 0.72;
    end;
    if (Flags and TONE_FLAG_SOFT_CONTRAST) <> 0 then
    begin
      V := ((V - 0.5) * 0.82) + 0.5;
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.08);
    end;
    Result := ClampByte(Round(V * 255.0));
  end;

begin
  if ToneMethodIsAdaptive(Method) or (Method < 0) or
     (Method >= TONE_METHOD_COUNT) then
    Method := TONE_STRIPLIGHT;
  for X := 0 to 255 do
    LUT[X] := AdjustChannel(X);
end;

function ToneIsNoOp(Method, Flags, Contrast, Brightness, Gamma,
  Strength: Integer): Boolean;
begin
  if Flags <> 0 then Exit(False);
  case Method of
    TONE_QUANTUM, TONE_CURVE_QUANTUM:
      Result := (Contrast = 64) and (Brightness = 0) and (Gamma = 0);
    TONE_CURVE, TONE_CURVE_GAMMA12:
      Result := False;
    TONE_AUTO_LEVELS:
      Result := False;
    TONE_CLAHE, TONE_LOCAL_EXPOSURE, TONE_BACKGROUND_FLATTEN:
      Result := (Strength <= 0) and (Contrast = 0) and (Brightness = 0) and
                (Gamma = 100);
  else
    Result := (Contrast = 0) and (Brightness = 0) and (Gamma = 100);
  end;
end;

procedure ApplyLUTGray(Data: PByte; Width, Height, Stride: Integer;
  const LUT: TToneLUT);
var
  X, Y: Integer;
  P: PByte;
begin
  if (Data = nil) or (Width <= 0) or (Height <= 0) then Exit;
  for Y := 0 to Height - 1 do
  begin
    P := Data + PtrInt(Y) * Stride;
    for X := 0 to Width - 1 do
    begin
      P^ := LUT[P^];
      Inc(P);
    end;
  end;
end;

{ ---------- Helpers for the adaptive methods ---------- }

procedure InvertGray(Data: PByte; Width, Height, Stride: Integer);
var
  X, Y: Integer;
  P: PByte;
begin
  for Y := 0 to Height - 1 do
  begin
    P := Data + PtrInt(Y) * Stride;
    for X := 0 to Width - 1 do
    begin
      P^ := 255 - P^;
      Inc(P);
    end;
  end;
end;

{ Box blur with edge replication, Passes times, on a W*H integer grid. }
procedure BoxBlurGrid(var A: TIntArray; W, H, Radius, Passes: Integer);
var
  Tmp: TIntArray;
  Pass, X, Y, I, Sum, Window: Integer;

  function ClampIdx(Value, Hi: Integer): Integer; inline;
  begin
    if Value < 0 then Result := 0
    else if Value > Hi then Result := Hi
    else Result := Value;
  end;

begin
  if (Radius < 1) or (W < 1) or (H < 1) then Exit;
  SetLength(Tmp, W * H);
  Window := 2 * Radius + 1;
  for Pass := 1 to Passes do
  begin
    { horizontal: A -> Tmp }
    for Y := 0 to H - 1 do
    begin
      Sum := 0;
      for I := -Radius to Radius do
        Inc(Sum, A[Y * W + ClampIdx(I, W - 1)]);
      for X := 0 to W - 1 do
      begin
        Tmp[Y * W + X] := Sum div Window;
        Inc(Sum, A[Y * W + ClampIdx(X + Radius + 1, W - 1)] -
                 A[Y * W + ClampIdx(X - Radius, W - 1)]);
      end;
    end;
    { vertical: Tmp -> A }
    for X := 0 to W - 1 do
    begin
      Sum := 0;
      for I := -Radius to Radius do
        Inc(Sum, Tmp[ClampIdx(I, H - 1) * W + X]);
      for Y := 0 to H - 1 do
      begin
        A[Y * W + X] := Sum div Window;
        Inc(Sum, Tmp[ClampIdx(Y + Radius + 1, H - 1) * W + X] -
                 Tmp[ClampIdx(Y - Radius, H - 1) * W + X]);
      end;
    end;
  end;
end;

procedure InitLowResMap(out Map: TLowResMap; Width, Height, Cell: Integer);
var
  X, FX, I0: Integer;
begin
  if Cell < 1 then Cell := 1;
  Map.Cell := Cell;
  Map.W := (Width + Cell - 1) div Cell;
  Map.H := (Height + Cell - 1) div Cell;
  SetLength(Map.V, Map.W * Map.H);
  SetLength(Map.XIdx, Width);
  SetLength(Map.XWgt, Width);
  SetLength(Map.RowTmp, Map.W);
  { Cell centres sit at (i + 0.5) * Cell. FX is the position in cells, 8.8. }
  for X := 0 to Width - 1 do
  begin
    FX := ((2 * X + 1) * 128) div Cell - 128;
    if FX < 0 then FX := 0;
    I0 := FX shr 8;
    if I0 >= Map.W - 1 then
    begin
      Map.XIdx[X] := Max(0, Map.W - 2);
      if Map.W > 1 then Map.XWgt[X] := 256 else Map.XWgt[X] := 0;
    end
    else
    begin
      Map.XIdx[X] := I0;
      Map.XWgt[X] := FX and 255;
    end;
  end;
end;

{ Fills Row[0..Width-1] with the map sampled along image row Y (0..255). }
procedure SampleLowResRow(var Map: TLowResMap; Y, Width: Integer; Row: PByte);
var
  FY, J0, J1, WY, X, I0, I1, WX, A, B: Integer;
begin
  FY := ((2 * Y + 1) * 128) div Map.Cell - 128;
  if FY < 0 then FY := 0;
  J0 := FY shr 8;
  WY := FY and 255;
  if J0 >= Map.H - 1 then
  begin
    J0 := Map.H - 1;
    J1 := J0;
    WY := 0;
  end
  else
    J1 := J0 + 1;
  for X := 0 to Map.W - 1 do
    Map.RowTmp[X] := (Map.V[J0 * Map.W + X] * (256 - WY) +
                      Map.V[J1 * Map.W + X] * WY) div 256;
  for X := 0 to Width - 1 do
  begin
    I0 := Map.XIdx[X];
    WX := Map.XWgt[X];
    if Map.W > 1 then I1 := I0 + 1 else I1 := I0;
    A := Map.RowTmp[I0];
    B := Map.RowTmp[I1];
    Row[X] := ClampByte(((A * (256 - WX) + B * WX) + 32768) shr 16);
  end;
end;

{ ---------- Auto levels ---------- }

{ Stretches the frame so that its darkest and brightest content use the full
  range. Statistics come from the central 80% of the frame so that film
  borders and gaps between frames do not decide the result.
  Strength = share of pixels clipped at each end: 0 = none, 100 = 2%.
  The stretch is limited to 4x so a blank frame is not turned into noise. }
procedure AutoLevelsGray(Data: PByte; Width, Height, Stride, Strength: Integer);
const
  MIN_RANGE = 64;   // 255 / 64 = at most about 4x
var
  Hist: array[0..255] of Int64;
  LUT: TToneLUT;
  X, Y, X0, X1, Y0, Y1, Lo, Hi, V: Integer;
  Total, ClipCount, Acc: Int64;
  P: PByte;
begin
  FillChar(Hist, SizeOf(Hist), 0);
  X0 := Width div 10;
  X1 := Width - X0;
  Y0 := Height div 10;
  Y1 := Height - Y0;
  if (X1 - X0 < 8) or (Y1 - Y0 < 8) then
  begin
    X0 := 0; X1 := Width; Y0 := 0; Y1 := Height;
  end;
  for Y := Y0 to Y1 - 1 do
  begin
    P := Data + PtrInt(Y) * Stride + X0;
    for X := X0 to X1 - 1 do
    begin
      Inc(Hist[P^]);
      Inc(P);
    end;
  end;
  Total := Int64(X1 - X0) * (Y1 - Y0);
  ClipCount := (Total * Strength) div 5000;

  Lo := 0;
  Acc := 0;
  while Lo < 255 do
  begin
    Inc(Acc, Hist[Lo]);
    if Acc > ClipCount then Break;
    Inc(Lo);
  end;
  Hi := 255;
  Acc := 0;
  while Hi > 0 do
  begin
    Inc(Acc, Hist[Hi]);
    if Acc > ClipCount then Break;
    Dec(Hi);
  end;
  if Hi - Lo < MIN_RANGE then
  begin
    { Widen the range around its middle, keeping it inside 0..255. }
    V := (Lo + Hi) div 2;
    Lo := V - MIN_RANGE div 2;
    Hi := Lo + MIN_RANGE;
    if Lo < 0 then
    begin
      Lo := 0;
      Hi := MIN_RANGE;
    end
    else if Hi > 255 then
    begin
      Hi := 255;
      Lo := 255 - MIN_RANGE;
    end;
  end;
  if (Lo = 0) and (Hi = 255) then Exit;

  for V := 0 to 255 do
    LUT[V] := ClampByte(((V - Lo) * 255 + (Hi - Lo) div 2) div (Hi - Lo));
  ApplyLUTGray(Data, Width, Height, Stride, LUT);
end;

{ ---------- CLAHE ---------- }

{ Contrast-limited adaptive histogram equalisation. The frame is divided into
  tiles, each tile gets its own equalising curve, and curves are blended
  between tile centres so no tile edges show. The clip limit keeps flat areas
  (film grain, blank paper) from being amplified into noise.
  Strength sets the clip limit: 0 = no change, 100 = strongest. }
procedure CLAHEGray(Data: PByte; Width, Height, Stride, Strength: Integer);
var
  TileSize, TX, TY, I, J, X, Y, V, N, Clip, Excess, Add, Rest, Step: Integer;
  X0, X1, Y0, Y1: Integer;
  Hist: array[0..255] of Integer;
  Maps: array of TToneLUT;
  ColI0, ColI1, ColW: TIntArray;
  RowJ0, RowJ1, WY, WX, FX, Acc: Integer;
  P: PByte;
  M00, M01, M10, M11: ^TToneLUT;
  ClipFactor: Double;
begin
  if Strength <= 0 then Exit;
  if (Width < 16) or (Height < 16) then Exit;
  if Strength > 100 then Strength := 100;

  TileSize := Max(32, Min(Width, Height) div 8);
  TX := Max(1, Min(32, (Width + TileSize div 2) div TileSize));
  TY := Max(1, Min(32, (Height + TileSize div 2) div TileSize));
  ClipFactor := 1.0 + Strength * 0.03;

  SetLength(Maps, TX * TY);
  for J := 0 to TY - 1 do
  begin
    Y0 := Int64(J) * Height div TY;
    Y1 := Int64(J + 1) * Height div TY;
    for I := 0 to TX - 1 do
    begin
      X0 := Int64(I) * Width div TX;
      X1 := Int64(I + 1) * Width div TX;
      FillChar(Hist, SizeOf(Hist), 0);
      for Y := Y0 to Y1 - 1 do
      begin
        P := Data + PtrInt(Y) * Stride + X0;
        for X := X0 to X1 - 1 do
        begin
          Inc(Hist[P^]);
          Inc(P);
        end;
      end;
      N := (X1 - X0) * (Y1 - Y0);
      if N <= 0 then
      begin
        for V := 0 to 255 do Maps[J * TX + I][V] := V;
        Continue;
      end;

      Clip := Max(1, Round(ClipFactor * N / 256.0));
      Excess := 0;
      for V := 0 to 255 do
        if Hist[V] > Clip then
        begin
          Inc(Excess, Hist[V] - Clip);
          Hist[V] := Clip;
        end;
      Add := Excess div 256;
      Rest := Excess - Add * 256;
      for V := 0 to 255 do
        Inc(Hist[V], Add);
      if Rest > 0 then
      begin
        Step := Max(1, 256 div Rest);
        V := 0;
        while (V < 256) and (Rest > 0) do
        begin
          Inc(Hist[V]);
          Dec(Rest);
          Inc(V, Step);
        end;
      end;

      Acc := 0;
      for V := 0 to 255 do
      begin
        Inc(Acc, Hist[V]);
        Maps[J * TX + I][V] := ClampByte((Int64(Acc) * 255 + N div 2) div N);
      end;
    end;
  end;

  { Per-column tile indices and blend weights (0..256). }
  SetLength(ColI0, Width);
  SetLength(ColI1, Width);
  SetLength(ColW, Width);
  for X := 0 to Width - 1 do
  begin
    { position in tiles, 8.8 fixed, relative to tile centres }
    FX := Integer((Int64(2 * X + 1) * TX * 128) div Width) - 128;
    if FX < 0 then FX := 0;
    I := FX shr 8;
    if I >= TX - 1 then
    begin
      ColI0[X] := TX - 1;
      ColI1[X] := TX - 1;
      ColW[X] := 0;
    end
    else
    begin
      ColI0[X] := I;
      ColI1[X] := I + 1;
      ColW[X] := FX and 255;
    end;
  end;

  for Y := 0 to Height - 1 do
  begin
    FX := Integer((Int64(2 * Y + 1) * TY * 128) div Height) - 128;
    if FX < 0 then FX := 0;
    J := FX shr 8;
    if J >= TY - 1 then
    begin
      RowJ0 := TY - 1;
      RowJ1 := TY - 1;
      WY := 0;
    end
    else
    begin
      RowJ0 := J;
      RowJ1 := J + 1;
      WY := FX and 255;
    end;
    P := Data + PtrInt(Y) * Stride;
    for X := 0 to Width - 1 do
    begin
      V := P^;
      WX := ColW[X];
      M00 := @Maps[RowJ0 * TX + ColI0[X]];
      M01 := @Maps[RowJ0 * TX + ColI1[X]];
      M10 := @Maps[RowJ1 * TX + ColI0[X]];
      M11 := @Maps[RowJ1 * TX + ColI1[X]];
      P^ := ((M00^[V] * (256 - WX) + M01^[V] * WX) * (256 - WY) +
             (M10^[V] * (256 - WX) + M11^[V] * WX) * WY + 32768) shr 16;
      Inc(P);
    end;
  end;
end;

{ ---------- Exposure balance ---------- }

{ Local gamma correction. A heavily blurred copy of the frame says how bright
  each neighbourhood is; dark neighbourhoods are brightened and bright ones
  darkened, so detail comes back in both at once. This is the method for
  frames that are underexposed in one part and overexposed in another.
  Strength: 0 = no change, 50 = classic, 100 = strongest. }
procedure LocalExposureGray(Data: PByte; Width, Height, Stride,
  Strength: Integer);
var
  Map: TLowResMap;
  Cell, CX, CY, X, Y, X0, X1, Y0, Y1, M, V, Radius: Integer;
  Sum: Int64;
  P, Row, MRow: PByte;
  Table: array of Byte;       // [mean 0..255][value 0..255]
  A, Expo: Double;
  RowBuf: array of Byte;
begin
  if Strength <= 0 then Exit;
  if (Width < 8) or (Height < 8) then Exit;
  if Strength > 100 then Strength := 100;

  Cell := Max(1, Min(Width, Height) div 128);
  InitLowResMap(Map, Width, Height, Cell);
  for CY := 0 to Map.H - 1 do
  begin
    Y0 := CY * Cell;
    Y1 := Min(Height, Y0 + Cell);
    for CX := 0 to Map.W - 1 do
    begin
      X0 := CX * Cell;
      X1 := Min(Width, X0 + Cell);
      Sum := 0;
      for Y := Y0 to Y1 - 1 do
      begin
        P := Data + PtrInt(Y) * Stride + X0;
        for X := X0 to X1 - 1 do
        begin
          Inc(Sum, P^);
          Inc(P);
        end;
      end;
      Map.V[CY * Map.W + CX] :=
        Integer((Sum * 256) div (Int64(X1 - X0) * (Y1 - Y0)));
    end;
  end;
  Radius := Max(1, Min(Map.W, Map.H) div 16);
  BoxBlurGrid(Map.V, Map.W, Map.H, Radius, 3);

  A := Strength / 50.0;
  SetLength(Table, 256 * 256);
  for M := 0 to 255 do
  begin
    Expo := Power(2.0, A * (2.0 * M / 255.0 - 1.0));
    Table[M * 256] := 0;
    for V := 1 to 255 do
      Table[M * 256 + V] := ClampByte(Round(255.0 * Power(V / 255.0, Expo)));
  end;

  SetLength(RowBuf, Width);
  MRow := @RowBuf[0];
  for Y := 0 to Height - 1 do
  begin
    SampleLowResRow(Map, Y, Width, MRow);
    Row := Data + PtrInt(Y) * Stride;
    for X := 0 to Width - 1 do
      Row[X] := Table[MRow[X] * 256 + Row[X]];
  end;
end;

{ ---------- Background flatten ---------- }

{ Estimates how bright the paper is in each part of the frame and divides it
  out, so unevenly lit or unevenly exposed pages end up with an even, light
  background and text keeps its contrast everywhere.
  Strength: 0 = no change, 100 = fully flattened. }
procedure BackgroundFlattenGray(Data: PByte; Width, Height, Stride,
  Strength: Integer);
const
  TARGET_BG = 240;
  MAX_GAIN = 6.0;
  NO_PAPER_BELOW = 24;   // darker than this: film border, leave alone
  FULL_GAIN_FROM = 48;   // from here up: full correction
var
  Map: TLowResMap;
  Cell, CX, CY, X, Y, X0, X1, Y0, Y1, V, Need, Acc, B, DX, DY, Best: Integer;
  Hist: array[0..255] of Integer;
  Dilated: TIntArray;
  P, Row, BRow: PByte;
  GainFix: array[0..255] of Integer;   // 16.16 fixed gain per background level
  Gain, S: Double;
  RowBuf: array of Byte;
begin
  if Strength <= 0 then Exit;
  if (Width < 16) or (Height < 16) then Exit;
  if Strength > 100 then Strength := 100;

  Cell := Max(4, Min(Width, Height) div 48);
  InitLowResMap(Map, Width, Height, Cell);
  for CY := 0 to Map.H - 1 do
  begin
    Y0 := CY * Cell;
    Y1 := Min(Height, Y0 + Cell);
    for CX := 0 to Map.W - 1 do
    begin
      X0 := CX * Cell;
      X1 := Min(Width, X0 + Cell);
      FillChar(Hist, SizeOf(Hist), 0);
      for Y := Y0 to Y1 - 1 do
      begin
        P := Data + PtrInt(Y) * Stride + X0;
        for X := X0 to X1 - 1 do
        begin
          Inc(Hist[P^]);
          Inc(P);
        end;
      end;
      { 90th percentile: the paper level, ignoring ink and specks }
      Need := ((X1 - X0) * (Y1 - Y0)) div 10;
      Acc := 0;
      V := 255;
      while V > 0 do
      begin
        Inc(Acc, Hist[V]);
        if Acc > Need then Break;
        Dec(V);
      end;
      Map.V[CY * Map.W + CX] := V * 256;
    end;
  end;

  { A cell fully covered by dark content has no paper in it. Borrow the
    brightest neighbour so it is not blown up to white. }
  SetLength(Dilated, Map.W * Map.H);
  for CY := 0 to Map.H - 1 do
    for CX := 0 to Map.W - 1 do
    begin
      Best := 0;
      for DY := -2 to 2 do
        for DX := -2 to 2 do
          if (CX + DX >= 0) and (CX + DX < Map.W) and
             (CY + DY >= 0) and (CY + DY < Map.H) then
            Best := Max(Best, Map.V[(CY + DY) * Map.W + CX + DX]);
      Dilated[CY * Map.W + CX] := Best;
    end;
  Map.V := Dilated;
  BoxBlurGrid(Map.V, Map.W, Map.H, 2, 2);

  S := Strength / 100.0;
  for B := 0 to 255 do
  begin
    if B <= NO_PAPER_BELOW then
      Gain := 1.0
    else
    begin
      Gain := TARGET_BG / B;
      if Gain > MAX_GAIN then Gain := MAX_GAIN;
      if B < FULL_GAIN_FROM then
        Gain := 1.0 + (Gain - 1.0) * (B - NO_PAPER_BELOW) /
                (FULL_GAIN_FROM - NO_PAPER_BELOW);
    end;
    Gain := 1.0 + (Gain - 1.0) * S;
    GainFix[B] := Round(Gain * 65536.0);
  end;

  SetLength(RowBuf, Width);
  BRow := @RowBuf[0];
  for Y := 0 to Height - 1 do
  begin
    SampleLowResRow(Map, Y, Width, BRow);
    Row := Data + PtrInt(Y) * Stride;
    for X := 0 to Width - 1 do
    begin
      V := (Int64(Row[X]) * GainFix[BRow[X]] + 32768) shr 16;
      if V > 255 then V := 255;
      Row[X] := V;
    end;
  end;
end;

{ ---------- Entry points ---------- }

procedure ApplyAdaptiveGray(Data: PByte; Width, Height, Stride: Integer;
  Method, Strength: Integer; InvertedPolarity: Boolean);
begin
  if (Data = nil) or (Width <= 0) or (Height <= 0) then Exit;
  if Strength < TONE_STRENGTH_MIN then Strength := TONE_STRENGTH_MIN;
  if Strength > TONE_STRENGTH_MAX then Strength := TONE_STRENGTH_MAX;
  { The three local methods also bring the frame to full range (a gentle
    auto levels), so one setting copes with dark, bright and mixed frames
    on the same roll. }
  case Method of
    TONE_AUTO_LEVELS:
      AutoLevelsGray(Data, Width, Height, Stride, Strength);
    TONE_CLAHE:
      if Strength > 0 then
      begin
        AutoLevelsGray(Data, Width, Height, Stride, NORMALISE_CLIP);
        CLAHEGray(Data, Width, Height, Stride, Strength);
      end;
    TONE_LOCAL_EXPOSURE:
      if Strength > 0 then
      begin
        AutoLevelsGray(Data, Width, Height, Stride, NORMALISE_CLIP);
        LocalExposureGray(Data, Width, Height, Stride, Strength);
      end;
    TONE_BACKGROUND_FLATTEN:
      if Strength > 0 then
      begin
        { Flattening assumes a light background. For a negative, work on the
          inverted image and turn it back afterwards. }
        if InvertedPolarity then InvertGray(Data, Width, Height, Stride);
        BackgroundFlattenGray(Data, Width, Height, Stride, Strength);
        AutoLevelsGray(Data, Width, Height, Stride, NORMALISE_CLIP);
        if InvertedPolarity then InvertGray(Data, Width, Height, Stride);
      end;
  end;
end;

procedure ApplyToneGray(Data: PByte; Width, Height, Stride: Integer;
  Method, Flags, Contrast, Brightness, Gamma, Strength: Integer;
  InvertedPolarity: Boolean);
var
  LUT: TToneLUT;
begin
  if (Data = nil) or (Width <= 0) or (Height <= 0) then Exit;
  if ToneIsNoOp(Method, Flags, Contrast, Brightness, Gamma, Strength) then Exit;

  if ToneMethodIsAdaptive(Method) then
  begin
    ApplyAdaptiveGray(Data, Width, Height, Stride, Method, Strength,
      InvertedPolarity);
    if ToneIsNoOp(TONE_STRIPLIGHT, Flags, Contrast, Brightness, Gamma, 0) then
      Exit;
    BuildToneLUT(TONE_STRIPLIGHT, Flags, Contrast, Brightness, Gamma, LUT);
  end
  else
    BuildToneLUT(Method, Flags, Contrast, Brightness, Gamma, LUT);
  ApplyLUTGray(Data, Width, Height, Stride, LUT);
end;

end.
