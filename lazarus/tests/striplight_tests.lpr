program striplight_tests;

{ Command-line checks for the units that have no GUI dependency.

    striplight_tests check
        Verifies that the shared tone lookup tables match the original
        Striplight math, that the grayscale frame assembly matches the
        original BGRA steps pixel for pixel, and exercises the strip cache
        from several threads.

    striplight_tests tone <in.jpg> <out.jpg> <method> [strength] [contrast]
                          [brightness] [gamma] [flags] [negative 0|1]
        Applies one tone method to a grayscale JPEG, for trying methods on
        real scans outside the application.

    striplight_tests bench <strip.jpg> [frames] [threads]
        Times the old-style and new-style frame build + encode.

  Build:  fpc -O2 -Fu.. tests/striplight_tests.lpr }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  Classes, SysUtils, Types, Math, uToneAdjust, uTurboRaw, uFrameGray;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: String);
begin
  if not Cond then
  begin
    Inc(Failures);
    WriteLn('FAIL: ', Msg);
  end;
end;

{ ------------------------------------------------------------------ }
{ Reference: the original lookup-table math, copied from the export   }
{ worker of the original Striplight source.                           }
{ ------------------------------------------------------------------ }

procedure OriginalLUT(Method, Flags, Contrast, Brightness, Gamma: Integer;
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
  ADJ_FLAG_SHADOW_LIFT = 1;
  ADJ_FLAG_HIGHLIGHT_RECOVERY = 2;
  ADJ_FLAG_S_CURVE = 4;
  ADJ_FLAG_DOCUMENT_RESCUE = 8;
  ADJ_FLAG_SOFT_CONTRAST = 16;
var
  X: Integer;

  function ClampByte(Value: Integer): Byte;
  begin
    if Value < 0 then Result := 0
    else if Value > 255 then Result := 255
    else Result := Value;
  end;

  function AdjustChannel(Value: Integer): Byte;
  var
    V, C, G: Double;
    In12, Out12, I: Integer;
  begin
    V := Value / 255.0;
    if Method in [2, 3, 4] then
    begin
      In12 := Round(V * 4095.0);
      if Method = 3 then
        Out12 := CURVE_GAMMA12_OUT[CURVE_POINT_COUNT - 1]
      else
        Out12 := CURVE_OUT[CURVE_POINT_COUNT - 1];
      for I := 0 to CURVE_POINT_COUNT - 2 do
        if In12 <= CURVE_IN[I + 1] then
        begin
          if Method = 3 then
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

    if Method in [1, 4] then
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

    if (Flags and ADJ_FLAG_SHADOW_LIFT) <> 0 then
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.45);
    if (Flags and ADJ_FLAG_HIGHLIGHT_RECOVERY) <> 0 then
      V := V / (V + (1.0 - V) * 1.20);
    if (Flags and ADJ_FLAG_S_CURVE) <> 0 then
      V := V * V * (3.0 - 2.0 * V);
    if (Flags and ADJ_FLAG_DOCUMENT_RESCUE) <> 0 then
    begin
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.35);
      if V > 0.70 then
        V := 0.70 + (V - 0.70) * 0.72;
    end;
    if (Flags and ADJ_FLAG_SOFT_CONTRAST) <> 0 then
    begin
      V := ((V - 0.5) * 0.82) + 0.5;
      V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.08);
    end;
    Result := ClampByte(Round(V * 255.0));
  end;

begin
  for X := 0 to 255 do
    LUT[X] := AdjustChannel(X);
end;

procedure TestLUTs;
var
  Method, Flags, C, B, G, I, Combos: Integer;
  A, R: TToneLUT;
  CMin, CMax, CStep, BMin, BMax, BStep, GMin, GMax, GStep: Integer;
  Same: Boolean;
begin
  Combos := 0;
  for Method := 0 to 4 do
  begin
    if Method in [1, 4] then
    begin
      CMin := -128; CMax := 255; CStep := 47;
      BMin := -128; BMax := 127; BStep := 51;
      GMin := -255; GMax := 255; GStep := 85;
    end
    else
    begin
      CMin := -100; CMax := 100; CStep := 25;
      BMin := -100; BMax := 100; BStep := 40;
      GMin := 10; GMax := 300; GStep := 58;
    end;
    for Flags := 0 to 31 do
    begin
      C := CMin;
      while C <= CMax do
      begin
        B := BMin;
        while B <= BMax do
        begin
          G := GMin;
          while G <= GMax do
          begin
            OriginalLUT(Method, Flags, C, B, G, R);
            BuildToneLUT(Method, Flags, C, B, G, A);
            Same := True;
            for I := 0 to 255 do
              if A[I] <> R[I] then Same := False;
            Check(Same, Format('LUT differs: method %d flags %d c %d b %d g %d',
              [Method, Flags, C, B, G]));
            Inc(Combos);
            Inc(G, GStep);
          end;
          Inc(B, BStep);
        end;
        Inc(C, CStep);
      end;
    end;
  end;
  WriteLn('  lookup tables: ', Combos, ' parameter sets compared with the original math');
end;

{ ------------------------------------------------------------------ }
{ Reference: the original BGRA frame assembly, one obvious step at a  }
{ time, on a plain 2D byte image (gray source, so R = G = B).         }
{ ------------------------------------------------------------------ }

type
  TRefImage = record
    W, H: Integer;
    Px: array of Byte;
  end;

function RefNew(W, H: Integer): TRefImage;
begin
  Result.W := W;
  Result.H := H;
  SetLength(Result.Px, W * H);
  if W * H > 0 then
    FillChar(Result.Px[0], W * H, 0);
end;

function RefGetPart(const S: TRefImage; const R: TRect): TRefImage;
var
  X, Y: Integer;
begin
  Result := RefNew(R.Right - R.Left, R.Bottom - R.Top);
  for Y := 0 to Result.H - 1 do
    for X := 0 to Result.W - 1 do
      Result.Px[Y * Result.W + X] := S.Px[(R.Top + Y) * S.W + R.Left + X];
end;

function RefRotateCW(const S: TRefImage): TRefImage;
var
  X, Y: Integer;
begin
  Result := RefNew(S.H, S.W);
  for Y := 0 to S.H - 1 do
    for X := 0 to S.W - 1 do
      Result.Px[X * Result.W + (S.H - 1 - Y)] := S.Px[Y * S.W + X];
end;

function RefRotateCCW(const S: TRefImage): TRefImage;
var
  X, Y: Integer;
begin
  Result := RefNew(S.H, S.W);
  for Y := 0 to S.H - 1 do
    for X := 0 to S.W - 1 do
      Result.Px[(S.W - 1 - X) * Result.W + Y] := S.Px[Y * S.W + X];
end;

procedure RefFlipH(var S: TRefImage);
var
  X, Y: Integer;
  T: Byte;
begin
  for Y := 0 to S.H - 1 do
    for X := 0 to S.W div 2 - 1 do
    begin
      T := S.Px[Y * S.W + X];
      S.Px[Y * S.W + X] := S.Px[Y * S.W + S.W - 1 - X];
      S.Px[Y * S.W + S.W - 1 - X] := T;
    end;
end;

procedure RefFlipV(var S: TRefImage);
var
  X, Y: Integer;
  T: Byte;
begin
  for Y := 0 to S.H div 2 - 1 do
    for X := 0 to S.W - 1 do
    begin
      T := S.Px[Y * S.W + X];
      S.Px[Y * S.W + X] := S.Px[(S.H - 1 - Y) * S.W + X];
      S.Px[(S.H - 1 - Y) * S.W + X] := T;
    end;
end;

procedure RefPutImage(var D: TRefImage; DX, DY: Integer; const S: TRefImage);
var
  X, Y: Integer;
begin
  for Y := 0 to S.H - 1 do
    for X := 0 to S.W - 1 do
      if (DX + X >= 0) and (DX + X < D.W) and (DY + Y >= 0) and (DY + Y < D.H) then
        D.Px[(DY + Y) * D.W + DX + X] := S.Px[Y * S.W + X];
end;

procedure RefSharpen(var S: TRefImage; Mode, Amount: Integer);
var
  Src: TRefImage;
  X, Y, DX, DY, V: Integer;
  Strength, Blur: Double;
begin
  if (S.W < 3) or (S.H < 3) then Exit;
  Amount := Max(0, Min(100, Amount));
  if Amount <= 0 then Exit;
  case Mode of
    1: Strength := 0.45 + Amount / 70.0;
    2: Strength := 0.65 + Amount / 48.0;
    3: Strength := 0.90 + Amount / 36.0;
  else
    Strength := 0.25 + Amount / 120.0;
  end;
  Src := S;
  SetLength(Src.Px, Length(Src.Px));   // unique copy
  for Y := 1 to S.H - 2 do
    for X := 1 to S.W - 2 do
    begin
      Blur := 0;
      for DY := -1 to 1 do
        for DX := -1 to 1 do
          Blur := Blur + Src.Px[(Y + DY) * S.W + X + DX];
      Blur := Blur / 9.0;
      V := Round(Src.Px[Y * S.W + X] + (Src.Px[Y * S.W + X] - Blur) * Strength);
      if V < 0 then V := 0 else if V > 255 then V := 255;
      S.Px[Y * S.W + X] := V;
    end;
end;

function SameAsRef(const F: TGrayFrame; const R: TRefImage): Boolean;
begin
  Result := (F.Width = R.W) and (F.Height = R.H) and
    ((R.W * R.H = 0) or (CompareByte(F.Data^, R.Px[0], R.W * R.H) = 0));
end;

procedure TestGeometry;
var
  Trial, I, StripW, StripH, NSeg, Seg, TotalW, MaxH, OffsetX, Rot: Integer;
  Strips: array[0..2] of TRefImage;
  Crops: array[0..2] of TRect;
  Transpose, FlipH, FlipV, Neg: Boolean;
  RefComposed, RefSeg, RefCrop, RefOut, RefTmp: TRefImage;
  F: TGrayFrame;
  SharpMode, SharpAmount, Method, Flags: Integer;
  LUT: TToneLUT;
begin
  RandSeed := 12345;
  for Trial := 1 to 400 do
  begin
    StripW := 20 + Random(140);
    StripH := 20 + Random(140);
    NSeg := 1 + Random(3);
    Transpose := Random(2) = 1;
    TotalW := 0;
    MaxH := 0;
    for Seg := 0 to NSeg - 1 do
    begin
      Strips[Seg] := RefNew(StripW, StripH);
      for I := 0 to StripW * StripH - 1 do
        Strips[Seg].Px[I] := Random(256);
      Crops[Seg].Left := Random(StripW - 4);
      Crops[Seg].Right := Crops[Seg].Left + 1 + Random(StripW - Crops[Seg].Left);
      Crops[Seg].Top := Random(StripH - 4);
      Crops[Seg].Bottom := Crops[Seg].Top + 1 + Random(StripH - Crops[Seg].Top);
      Inc(TotalW, Crops[Seg].Bottom - Crops[Seg].Top);
      MaxH := Max(MaxH, Crops[Seg].Right - Crops[Seg].Left);
    end;

    { original steps }
    RefComposed := RefNew(TotalW, MaxH);
    OffsetX := 0;
    for Seg := 0 to NSeg - 1 do
    begin
      RefCrop := RefGetPart(Strips[Seg], Crops[Seg]);
      if Transpose then
      begin
        RefSeg := RefRotateCW(RefCrop);
        RefFlipH(RefSeg);
      end
      else
        RefSeg := RefRotateCCW(RefCrop);
      RefPutImage(RefComposed, OffsetX, 0, RefSeg);
      Inc(OffsetX, RefSeg.W);
    end;
    Rot := Random(4) * 90;
    FlipH := Random(2) = 1;
    FlipV := Random(2) = 1;
    Neg := Random(2) = 1;
    case Rot of
      90: RefOut := RefRotateCW(RefComposed);
      180:
        begin
          RefTmp := RefRotateCW(RefComposed);
          RefOut := RefRotateCW(RefTmp);
        end;
      270: RefOut := RefRotateCCW(RefComposed);
    else
      RefOut := RefGetPart(RefComposed, Rect(0, 0, RefComposed.W, RefComposed.H));
    end;
    if FlipH then RefFlipH(RefOut);
    if FlipV then RefFlipV(RefOut);
    Method := Random(5);
    Flags := Random(32);
    OriginalLUT(Method, Flags, 10, -5, IfThen(Method in [1, 4], 20, 120), LUT);
    for I := 0 to RefOut.W * RefOut.H - 1 do
      RefOut.Px[I] := LUT[RefOut.Px[I]];
    if Neg then
      for I := 0 to RefOut.W * RefOut.H - 1 do
        RefOut.Px[I] := 255 - RefOut.Px[I];
    SharpMode := Random(4);
    SharpAmount := Random(3) * 45;
    RefSharpen(RefOut, SharpMode, SharpAmount);

    { new steps }
    GrayFrameAlloc(F, TotalW, MaxH);
    try
      OffsetX := 0;
      for Seg := 0 to NSeg - 1 do
      begin
        GrayBlitRotated(@Strips[Seg].Px[0], StripW, StripH, Crops[Seg],
          Transpose, F, OffsetX);
        Inc(OffsetX, Crops[Seg].Bottom - Crops[Seg].Top);
      end;
      GrayOrient(F, Rot, FlipH, FlipV);
      ApplyToneGray(F.Data, F.Width, F.Height, F.Width, Method, Flags, 10, -5,
        IfThen(Method in [1, 4], 20, 120), 50, Neg);
      if Neg then GrayNegative(F);
      GraySharpen(F, SharpMode, SharpAmount);
      Check(SameAsRef(F, RefOut), Format('frame differs in trial %d (rot %d, ' +
        'segments %d, transpose %s, flipH %s, flipV %s, negative %s, ' +
        'method %d, flags %d, sharpen %d/%d, size %dx%d vs %dx%d)',
        [Trial, Rot, NSeg, BoolToStr(Transpose, True), BoolToStr(FlipH, True),
         BoolToStr(FlipV, True), BoolToStr(Neg, True), Method, Flags,
         SharpMode, SharpAmount, F.Width, F.Height, RefOut.W, RefOut.H]));
    finally
      GrayFrameFree(F);
    end;
  end;
  WriteLn('  frame assembly: 400 random frames compared with the original steps');
end;

{ ------------------------------------------------------------------ }
{ Adaptive methods: sanity, not equivalence.                          }
{ ------------------------------------------------------------------ }

procedure TestAdaptive;
var
  W, H, X, Y, Method, I, Lo, Hi: Integer;
  Img, Orig: array of Byte;
  Same: Boolean;
begin
  W := 400;
  H := 300;
  SetLength(Img, W * H);
  SetLength(Orig, W * H);
  { low-contrast underexposed ramp with texture }
  for Y := 0 to H - 1 do
    for X := 0 to W - 1 do
      Orig[Y * W + X] := 30 + (X * 50) div W + ((X xor Y) and 7);

  for Method := TONE_AUTO_LEVELS to TONE_BACKGROUND_FLATTEN do
  begin
    { strength 0 leaves the three blendable methods untouched }
    if Method <> TONE_AUTO_LEVELS then
    begin
      Move(Orig[0], Img[0], W * H);
      ApplyToneGray(@Img[0], W, H, W, Method, 0, 0, 0, 100, 0, False);
      Check(CompareByte(Img[0], Orig[0], W * H) = 0,
        Format('method %d changed the image at strength 0', [Method]));
    end;
    Move(Orig[0], Img[0], W * H);
    ApplyToneGray(@Img[0], W, H, W, Method, 0, 0, 0, 100, 60, False);
    Same := CompareByte(Img[0], Orig[0], W * H) = 0;
    Check(not Same, Format('method %d did nothing at strength 60', [Method]));
    Lo := 255;
    Hi := 0;
    for I := 0 to W * H - 1 do
    begin
      if Img[I] < Lo then Lo := Img[I];
      if Img[I] > Hi then Hi := Img[I];
    end;
    WriteLn(Format('  %-40s input range 30..87 -> output range %d..%d',
      [ToneMethodName(Method), Lo, Hi]));
  end;

  { odd sizes must not crash or read out of bounds }
  for Method := TONE_AUTO_LEVELS to TONE_BACKGROUND_FLATTEN do
    for I := 1 to 40 do
    begin
      W := 1 + Random(90);
      H := 1 + Random(90);
      SetLength(Img, W * H);
      for X := 0 to W * H - 1 do Img[X] := Random(256);
      ApplyToneGray(@Img[0], W, H, W, Method, Random(32), 0, 0, 100,
        Random(101), Random(2) = 1);
    end;
  WriteLn('  adaptive methods: small and odd sizes handled');
end;

{ ------------------------------------------------------------------ }
{ Strip cache under several threads.                                  }
{ ------------------------------------------------------------------ }

type
  TCacheThread = class(TThread)
  public
    Cache: TGrayStripCache;
    Paths: array of String;
    Sums: array of Int64;
    Errors: Integer;
    procedure Execute; override;
  end;

procedure TCacheThread.Execute;
var
  I, K, Idx: Integer;
  Strip: TGrayStrip;
  Err: String;
  Sum: Int64;
begin
  for I := 1 to 60 do
  begin
    Idx := Random(Length(Paths));
    if Cache.Acquire(Paths[Idx], Strip, Err) = sarOk then
    begin
      Sum := 0;
      for K := 0 to Strip.Width * Strip.Height - 1 do
        Inc(Sum, Strip.Data[K]);
      if Sum <> Sums[Idx] then Inc(Errors);
      Cache.Release(Strip);
    end
    else
      Inc(Errors);
  end;
  Cache.ReleaseOwner;
end;

procedure TestCacheAndJpeg(const TempDir: String);
const
  NFILES = 6;
  NTHREADS = 6;
var
  I, K, W, H, RW, RH: Integer;
  Px: array of Byte;
  Jpeg: TBytes;
  Err: String;
  Paths: array of String;
  Sums: array of Int64;
  Decoded: PByte;
  IsGray: Boolean;
  Cache: TGrayStripCache;
  Threads: array[0..NTHREADS - 1] of TCacheThread;
  TotalErrors: Integer;
  Strip: TGrayStrip;
begin
  if not TurboRawAvailable then
  begin
    WriteLn('  (TurboJPEG library not found: JPEG and cache checks skipped: ',
      TurboRawStatus, ')');
    Exit;
  end;
  W := 300;
  H := 200;
  SetLength(Px, W * H);
  SetLength(Paths, NFILES);
  SetLength(Sums, NFILES);
  for I := 0 to NFILES - 1 do
  begin
    for K := 0 to W * H - 1 do
      Px[K] := (K * (I + 3) + (K div W) * 5) and 255;
    Check(TurboEncode(@Px[0], W, H, W, TURBO_PF_GRAY, 100, False, Jpeg, Err),
      'gray encode: ' + Err);
    Paths[I] := TempDir + 'strip' + IntToStr(I) + '.jpg';
    Check(WriteBytesToFile(Paths[I], Jpeg, Err), 'write: ' + Err);
    Check(TurboLoadGrayFile(Paths[I], RW, RH, Decoded, IsGray, Err),
      'gray decode: ' + Err);
    Check((RW = W) and (RH = H) and IsGray, 'decoded size');
    Sums[I] := 0;
    for K := 0 to W * H - 1 do
      Inc(Sums[I], Decoded[K]);
    FreeMem(Decoded);
  end;

  { a colour JPEG must be reported as not gray, not decoded }
  SetLength(Px, W * H * 4);
  for K := 0 to W * H * 4 - 1 do Px[K] := (K * 7) and 255;
  Check(TurboEncode(@Px[0], W, H, W * 4, TURBO_PF_BGRA, 90, False, Jpeg, Err),
    'colour encode: ' + Err);
  Check(WriteBytesToFile(TempDir + 'colour.jpg', Jpeg, Err), 'write: ' + Err);
  Check(not TurboLoadGrayFile(TempDir + 'colour.jpg', RW, RH, Decoded, IsGray, Err),
    'colour JPEG was decoded as gray');
  Check(not IsGray, 'colour JPEG not flagged');

  Cache := TGrayStripCache.Create(3, NTHREADS + 1);
  Check(Cache.Acquire(TempDir + 'colour.jpg', Strip, Err) = sarNotGray,
    'cache: colour strip');
  Check(Cache.Acquire(TempDir + 'missing.jpg', Strip, Err) = sarFailed,
    'cache: missing strip');
  for I := 0 to NTHREADS - 1 do
  begin
    Threads[I] := TCacheThread.Create(True);
    Threads[I].Cache := Cache;
    Threads[I].Paths := Paths;
    Threads[I].Sums := Sums;
    Threads[I].Start;
  end;
  TotalErrors := 0;
  for I := 0 to NTHREADS - 1 do
  begin
    Threads[I].WaitFor;
    Inc(TotalErrors, Threads[I].Errors);
    Threads[I].Free;
  end;
  Cache.ReleaseOwner;
  Check(TotalErrors = 0, Format('cache: %d wrong or failed reads', [TotalErrors]));
  for I := 0 to NFILES - 1 do
    DeleteFile(Paths[I]);
  DeleteFile(TempDir + 'colour.jpg');
  WriteLn('  strip cache: ', NTHREADS, ' threads, 360 reads, all correct');
end;

{ ------------------------------------------------------------------ }
{ tone command                                                        }
{ ------------------------------------------------------------------ }

function ArgInt(Index, Default: Integer): Integer;
begin
  if ParamCount >= Index then
    Result := StrToIntDef(ParamStr(Index), Default)
  else
    Result := Default;
end;

procedure RunTone;
var
  W, H, Method, Strength, Contrast, Brightness, Gamma, Flags: Integer;
  Pixels: PByte;
  IsGray, Negative: Boolean;
  Err: String;
  Jpeg: TBytes;
  T0: QWord;
begin
  if ParamCount < 4 then
  begin
    WriteLn('usage: striplight_tests tone <in.jpg> <out.jpg> <method 0..8> ',
      '[strength] [contrast] [brightness] [gamma] [flags] [negative 0|1]');
    Halt(2);
  end;
  Method := ArgInt(4, 0);
  Strength := ArgInt(5, TONE_STRENGTH_DEFAULT);
  if ToneMethodUsesQuantumRanges(Method) then
  begin
    Contrast := ArgInt(6, 64);
    Brightness := ArgInt(7, 0);
    Gamma := ArgInt(8, 0);
  end
  else
  begin
    Contrast := ArgInt(6, 0);
    Brightness := ArgInt(7, 0);
    Gamma := ArgInt(8, 100);
  end;
  Flags := ArgInt(9, 0);
  Negative := ArgInt(10, 0) <> 0;
  if not TurboLoadGrayFile(ParamStr(2), W, H, Pixels, IsGray, Err) then
  begin
    WriteLn('cannot load: ', Err);
    Halt(1);
  end;
  T0 := GetTickCount64;
  ApplyToneGray(Pixels, W, H, W, Method, Flags, Contrast, Brightness, Gamma,
    Strength, Negative);
  WriteLn(Format('%s  %dx%d  %d ms', [ToneMethodName(Method), W, H,
    GetTickCount64 - T0]));
  if not (TurboEncode(Pixels, W, H, W, TURBO_PF_GRAY, 92, False, Jpeg, Err) and
          WriteBytesToFile(ParamStr(3), Jpeg, Err)) then
  begin
    WriteLn('cannot save: ', Err);
    Halt(1);
  end;
  FreeMem(Pixels);
end;

{ ------------------------------------------------------------------ }
{ bench command                                                       }
{ ------------------------------------------------------------------ }

type
  TBenchThread = class(TThread)
  public
    StripPath: String;
    Frames, FrameW: Integer;
    NewPath, SharedLock: Boolean;
    Cache: TGrayStripCache;
    Lock: PRTLCriticalSection;
    OldSrc: array of LongWord;     // this worker's own decoded strip
    OldW, OldH: Integer;
    procedure Execute; override;
    procedure OldFrame;
    procedure NewFrame;
  end;

{ Old style, approximated: each worker decodes its own copy of the strip
  (once, then cached), every step works on 4 bytes per pixel, and the JPEG is
  compressed while holding the shared save lock. This imitates the cost of
  the original path; it is not the original code. }
procedure TBenchThread.OldFrame;
var
  W, H, X, Y, CW, CH: Integer;
  Gray: PByte;
  IsGray: Boolean;
  Err: String;
  Crop, Rot, Composed, Copy2: array of LongWord;
  GrayBuf: array of Byte;
  Jpeg: TBytes;
  LUT: TToneLUT;
  P: PByte;
begin
  if Length(OldSrc) = 0 then
  begin
    { per-worker decode to BGRA (decode gray, expand: same memory traffic) }
    if not TurboLoadGrayFile(StripPath, OldW, OldH, Gray, IsGray, Err) then Exit;
    SetLength(OldSrc, OldW * OldH);
    for X := 0 to OldW * OldH - 1 do
      OldSrc[X] := Gray[X] * LongWord($010101) or LongWord($FF000000);
    FreeMem(Gray);
  end;
  W := OldW;
  H := OldH;
  CW := W;                 // crop: full strip width, FrameW lines
  CH := Min(H, FrameW);
  SetLength(Crop, CW * CH);
  for Y := 0 to CH - 1 do
    Move(OldSrc[Y * W], Crop[Y * CW], CW * 4);
  SetLength(Rot, CW * CH);                      // RotateCCW -> CH x CW
  for Y := 0 to CH - 1 do
    for X := 0 to CW - 1 do
      Rot[(CW - 1 - X) * CH + Y] := Crop[Y * CW + X];
  SetLength(Composed, CW * CH);                 // PutImage
  Move(Rot[0], Composed[0], CW * CH * 4);
  SetLength(Copy2, CW * CH);                    // GetPart for rotation 0
  Move(Composed[0], Copy2[0], CW * CH * 4);
  BuildToneLUT(TONE_STRIPLIGHT, 0, 10, 5, 110, LUT);
  P := @Copy2[0];
  for X := 0 to CW * CH - 1 do
  begin
    P[0] := LUT[P[0]];
    P[1] := LUT[P[1]];
    P[2] := LUT[P[2]];
    Inc(P, 4);
  end;
  SetLength(GrayBuf, CW * CH);                  // BuildGrayBuffer
  P := @Copy2[0];
  for X := 0 to CW * CH - 1 do
  begin
    GrayBuf[X] := (P[2] * 77 + P[1] * 150 + P[0] * 29 + 128) shr 8;
    Inc(P, 4);
  end;
  EnterCriticalSection(Lock^);                  // encode inside the save lock
  try
    TurboEncode(@GrayBuf[0], CH, CW, CH, TURBO_PF_GRAY, 100, False, Jpeg, Err);
  finally
    LeaveCriticalSection(Lock^);
  end;
end;

procedure TBenchThread.NewFrame;
var
  Strip: TGrayStrip;
  Err: String;
  F: TGrayFrame;
  Jpeg: TBytes;
begin
  if Cache.Acquire(StripPath, Strip, Err) <> sarOk then Exit;
  try
    GrayFrameAlloc(F, Min(Strip.Height, FrameW), Strip.Width);
    try
      GrayBlitRotated(Strip.Data, Strip.Width, Strip.Height,
        Rect(0, 0, Strip.Width, Min(Strip.Height, FrameW)), False, F, 0);
      ApplyToneGray(F.Data, F.Width, F.Height, F.Width, TONE_STRIPLIGHT, 0,
        10, 5, 110, 50, False);
      TurboEncode(F.Data, F.Width, F.Height, F.Width, TURBO_PF_GRAY, 100,
        False, Jpeg, Err);                      // encode outside the lock
      EnterCriticalSection(Lock^);
      LeaveCriticalSection(Lock^);              // (file write would go here)
    finally
      GrayFrameFree(F);
    end;
  finally
    Cache.Release(Strip);
  end;
end;

procedure TBenchThread.Execute;
var
  I: Integer;
begin
  for I := 1 to Frames do
    if NewPath then NewFrame else OldFrame;
  if NewPath then Cache.ReleaseOwner;
end;

procedure RunBench;
var
  Threads: array of TBenchThread;
  NThreads, Frames, I, Pass: Integer;
  Lock: TRTLCriticalSection;
  Cache: TGrayStripCache;
  T0: QWord;
  Ms: array[0..1] of QWord;
begin
  if ParamCount < 2 then
  begin
    WriteLn('usage: striplight_tests bench <strip.jpg> [frames per thread] [threads]');
    Halt(2);
  end;
  Frames := ArgInt(3, 8);
  NThreads := ArgInt(4, 4);
  InitCriticalSection(Lock);
  SetLength(Threads, NThreads);
  for Pass := 0 to 1 do
  begin
    Cache := nil;
    if Pass = 1 then Cache := TGrayStripCache.Create(4, NThreads);
    T0 := GetTickCount64;
    for I := 0 to NThreads - 1 do
    begin
      Threads[I] := TBenchThread.Create(True);
      Threads[I].StripPath := ParamStr(2);
      Threads[I].Frames := Frames;
      Threads[I].FrameW := 3000;
      Threads[I].NewPath := Pass = 1;
      Threads[I].Cache := Cache;
      Threads[I].Lock := @Lock;
      Threads[I].Start;
    end;
    for I := 0 to NThreads - 1 do
    begin
      Threads[I].WaitFor;
      Threads[I].Free;
    end;
    Ms[Pass] := GetTickCount64 - T0;
  end;
  DoneCriticalSection(Lock);
  WriteLn(Format('%d threads x %d frames', [NThreads, Frames]));
  WriteLn(Format('  original-style path: %d ms  (%.0f ms per frame)',
    [Ms[0], Ms[0] / (NThreads * Frames)]));
  WriteLn(Format('  new grayscale path : %d ms  (%.0f ms per frame)',
    [Ms[1], Ms[1] / (NThreads * Frames)]));
  if Ms[1] > 0 then
    WriteLn(Format('  speed-up           : %.1fx', [Ms[0] / Ms[1]]));
end;

var
  Cmd, TempDir: String;
begin
  Cmd := LowerCase(ParamStr(1));
  if Cmd = 'tone' then
    RunTone
  else if Cmd = 'bench' then
    RunBench
  else if Cmd = 'check' then
  begin
    TempDir := IncludeTrailingPathDelimiter(GetTempDir(False));
    WriteLn('Striplight unit checks');
    TestLUTs;
    TestGeometry;
    TestAdaptive;
    TestCacheAndJpeg(TempDir);
    if Failures = 0 then
      WriteLn('ALL CHECKS PASSED')
    else
    begin
      WriteLn(Failures, ' CHECK(S) FAILED');
      Halt(1);
    end;
  end
  else
  begin
    WriteLn('usage: striplight_tests check | tone ... | bench ...');
    Halt(2);
  end;
end.
