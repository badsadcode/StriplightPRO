unit uFrameGray;

{ Frame assembly on 8-bit grayscale buffers for the fast export path.

  The original export path builds every frame as a 32-bit BGRA bitmap and
  copies it several times (crop, rotate, paste, copy, adjust, convert to gray
  for the encoder). Microfilm strips are grayscale, so this unit does the
  same steps on one byte per pixel and with fewer passes. The results are
  pixel-for-pixel the same as the BGRA path for grayscale sources.

  Also holds the shared strip cache: all export workers take decoded strips
  from one cache, so a strip that several workers need is decoded once. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Math, uTurboRaw;

type
  { An 8-bit grayscale image, Width bytes per row, top row first. }
  TGrayFrame = record
    Width, Height: Integer;
    Data: PByte;
  end;

  TGrayStrip = class
  private
    FPath: String;
    FRefCount: Integer;
    FLoading: Boolean;
    FLastUse: QWord;
  public
    Width, Height: Integer;
    Data: PByte;
    destructor Destroy; override;
  end;

  TStripAcquireResult = (sarOk, sarNotGray, sarFailed);

  { Thread-safe cache of decoded grayscale strips, shared by all export
    workers of one export run. Strips in use are never evicted. }
  TGrayStripCache = class
  private
    FLock: TRTLCriticalSection;
    FItems: TFPList;
    FLimit: Integer;
    FOwners: Integer;
    FUseCounter: QWord;
    FNotGray: TStringList;
    function FindLocked(const Path: String): TGrayStrip;
    procedure TrimLocked(KeepCount: Integer);
  public
    constructor Create(ALimit, AOwners: Integer);
    destructor Destroy; override;
    { Returns a decoded strip, loading it if needed. If another worker is
      already loading the same strip this waits for it instead of decoding a
      second copy. Every sarOk result must be paired with Release. }
    function Acquire(const Path: String; out Strip: TGrayStrip;
      out Err: String): TStripAcquireResult;
    procedure Release(Strip: TGrayStrip);
    { True when the strip is already decoded or being decoded. Lets callers
      skip a file-exists check, which is a round trip on a network share. }
    function Contains(const Path: String): Boolean;
    { Frees every strip that is not in use right now. }
    procedure DropUnused;
    { Each worker calls this once when it finishes; the cache frees itself
      when the last one has. }
    procedure ReleaseOwner;
  end;

procedure GrayFrameInit(out F: TGrayFrame);
procedure GrayFrameAlloc(out F: TGrayFrame; AWidth, AHeight: Integer);
procedure GrayFrameFree(var F: TGrayFrame);

{ Copies the crop rectangle of a strip into Dst, rotated the way the strip
  view shows it, with its left edge at DstX and its top at row 0.
  Transpose = False: rotate counter-clockwise.
  Transpose = True : rotate clockwise then mirror horizontally. }
procedure GrayBlitRotated(Src: PByte; SrcW, SrcH: Integer; const Crop: TRect;
  Transpose: Boolean; var Dst: TGrayFrame; DstX: Integer);

{ Rotates by 0/90/180/270 degrees clockwise, then mirrors. }
procedure GrayOrient(var F: TGrayFrame; Rotation: Integer; FlipH, FlipV: Boolean);

procedure GrayNegative(var F: TGrayFrame);

{ Same 3x3 sharpening as ApplySharpnessFilter in the main form. }
procedure GraySharpen(var F: TGrayFrame; Mode, Amount: Integer);

implementation

const
  BLOCK_ROWS = 32;

{ ---------- TGrayStrip ---------- }

destructor TGrayStrip.Destroy;
begin
  if Data <> nil then
    FreeMem(Data);
  Data := nil;
  inherited Destroy;
end;

{ ---------- TGrayStripCache ---------- }

constructor TGrayStripCache.Create(ALimit, AOwners: Integer);
begin
  inherited Create;
  InitCriticalSection(FLock);
  FItems := TFPList.Create;
  FNotGray := TStringList.Create;
  FNotGray.Sorted := True;
  FNotGray.Duplicates := dupIgnore;
  FLimit := Max(1, ALimit);
  FOwners := Max(1, AOwners);
  FUseCounter := 0;
end;

destructor TGrayStripCache.Destroy;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    TGrayStrip(FItems[I]).Free;
  FItems.Free;
  FNotGray.Free;
  DoneCriticalSection(FLock);
  inherited Destroy;
end;

function TGrayStripCache.FindLocked(const Path: String): TGrayStrip;
var
  I: Integer;
begin
  for I := 0 to FItems.Count - 1 do
    if TGrayStrip(FItems[I]).FPath = Path then
      Exit(TGrayStrip(FItems[I]));
  Result := nil;
end;

procedure TGrayStripCache.TrimLocked(KeepCount: Integer);
var
  I, Oldest: Integer;
  S: TGrayStrip;
begin
  while FItems.Count > KeepCount do
  begin
    Oldest := -1;
    for I := 0 to FItems.Count - 1 do
    begin
      S := TGrayStrip(FItems[I]);
      if (S.FRefCount = 0) and (not S.FLoading) and
         ((Oldest < 0) or (S.FLastUse < TGrayStrip(FItems[Oldest]).FLastUse)) then
        Oldest := I;
    end;
    if Oldest < 0 then Exit;          // everything left is in use
    TGrayStrip(FItems[Oldest]).Free;
    FItems.Delete(Oldest);
  end;
end;

function TGrayStripCache.Acquire(const Path: String; out Strip: TGrayStrip;
  out Err: String): TStripAcquireResult;
var
  S: TGrayStrip;
  W, H: Integer;
  Pixels: PByte;
  IsGray, Ok, MustLoad: Boolean;
begin
  Strip := nil;
  Err := '';
  S := nil;
  MustLoad := False;
  while True do
  begin
    EnterCriticalSection(FLock);
    try
      if FNotGray.IndexOf(Path) >= 0 then
        Exit(sarNotGray);
      S := FindLocked(Path);
      if S = nil then
      begin
        { Make room first so the cache does not grow past its limit. }
        TrimLocked(FLimit - 1);
        S := TGrayStrip.Create;
        S.FPath := Path;
        S.FLoading := True;
        S.FRefCount := 1;
        FItems.Add(S);
        MustLoad := True;
        Break;
      end
      else if not S.FLoading then
      begin
        Inc(S.FRefCount);
        Inc(FUseCounter);
        S.FLastUse := FUseCounter;
        Strip := S;
        Exit(sarOk);
      end;
    finally
      LeaveCriticalSection(FLock);
    end;
    Sleep(2);                         // another worker is decoding this strip
  end;

  if not MustLoad then Exit(sarFailed);

  Pixels := nil;
  IsGray := True;
  Ok := False;
  try
    Ok := TurboLoadGrayFile(Path, W, H, Pixels, IsGray, Err);
  except
    on E: Exception do
    begin
      Ok := False;
      Err := E.Message;
    end;
  end;

  EnterCriticalSection(FLock);
  try
    if Ok then
    begin
      S.Width := W;
      S.Height := H;
      S.Data := Pixels;
      S.FLoading := False;
      Inc(FUseCounter);
      S.FLastUse := FUseCounter;
      Strip := S;
      Result := sarOk;
    end
    else
    begin
      FItems.Remove(S);
      S.Free;
      if not IsGray then
      begin
        FNotGray.Add(Path);
        Result := sarNotGray;
      end
      else
        Result := sarFailed;
    end;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TGrayStripCache.Release(Strip: TGrayStrip);
begin
  if Strip = nil then Exit;
  EnterCriticalSection(FLock);
  try
    if Strip.FRefCount > 0 then
      Dec(Strip.FRefCount);
    TrimLocked(FLimit);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

function TGrayStripCache.Contains(const Path: String): Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Result := FindLocked(Path) <> nil;
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TGrayStripCache.DropUnused;
begin
  EnterCriticalSection(FLock);
  try
    TrimLocked(0);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TGrayStripCache.ReleaseOwner;
var
  Last: Boolean;
begin
  EnterCriticalSection(FLock);
  try
    Dec(FOwners);
    Last := FOwners <= 0;
  finally
    LeaveCriticalSection(FLock);
  end;
  if Last then
    Free;
end;

{ ---------- Frame buffers ---------- }

procedure GrayFrameInit(out F: TGrayFrame);
begin
  F.Width := 0;
  F.Height := 0;
  F.Data := nil;
end;

procedure GrayFrameAlloc(out F: TGrayFrame; AWidth, AHeight: Integer);
begin
  F.Width := AWidth;
  F.Height := AHeight;
  F.Data := nil;
  if (AWidth <= 0) or (AHeight <= 0) then
    raise Exception.Create('Frame has no visible image area.');
  GetMem(F.Data, PtrUInt(AWidth) * PtrUInt(AHeight));
  FillChar(F.Data^, PtrUInt(AWidth) * PtrUInt(AHeight), 0);
end;

procedure GrayFrameFree(var F: TGrayFrame);
begin
  if F.Data <> nil then
    FreeMem(F.Data);
  F.Data := nil;
  F.Width := 0;
  F.Height := 0;
end;

{ ---------- Geometry ---------- }

procedure GrayBlitRotated(Src: PByte; SrcW, SrcH: Integer; const Crop: TRect;
  Transpose: Boolean; var Dst: TGrayFrame; DstX: Integer);
var
  X0, Y0, CW, CH, SegW, SegH, Row0, RowCount, K, SY, SrcCol: Integer;
  SrcRow, DstCell: PByte;
  DstStride: PtrInt;
begin
  if (Src = nil) or (Dst.Data = nil) then Exit;
  X0 := Max(0, Crop.Left);
  Y0 := Max(0, Crop.Top);
  CW := Min(SrcW, Crop.Right) - X0;
  CH := Min(SrcH, Crop.Bottom) - Y0;
  if (CW <= 0) or (CH <= 0) then Exit;

  { The rotated segment is CH wide and CW high. Clip it to the destination. }
  SegW := CH;
  SegH := CW;
  if DstX < 0 then Exit;
  if DstX + SegW > Dst.Width then SegW := Dst.Width - DstX;
  if SegH > Dst.Height then SegH := Dst.Height;
  if (SegW <= 0) or (SegH <= 0) then Exit;

  { Destination row K takes source column X0+K (transpose) or
    X0+CW-1-K (counter-clockwise); destination column DstX+SY takes source
    row Y0+SY. Working through a small block of destination rows at a time
    keeps both the source and the destination in the CPU cache. }
  DstStride := Dst.Width;
  Row0 := 0;
  while Row0 < SegH do
  begin
    RowCount := Min(BLOCK_ROWS, SegH - Row0);
    for SY := 0 to SegW - 1 do
    begin
      SrcRow := Src + PtrInt(Y0 + SY) * SrcW;
      DstCell := Dst.Data + PtrInt(Row0) * DstStride + DstX + SY;
      if Transpose then
      begin
        SrcCol := X0 + Row0;
        for K := 0 to RowCount - 1 do
        begin
          DstCell^ := SrcRow[SrcCol + K];
          Inc(DstCell, DstStride);
        end;
      end
      else
      begin
        SrcCol := X0 + CW - 1 - Row0;
        for K := 0 to RowCount - 1 do
        begin
          DstCell^ := SrcRow[SrcCol - K];
          Inc(DstCell, DstStride);
        end;
      end;
    end;
    Inc(Row0, RowCount);
  end;
end;

procedure RotateQuarter(var F: TGrayFrame; Clockwise: Boolean);
var
  NewData, SrcRow, DstCell: PByte;
  NW, NH, Row0, RowCount, K, SY, SrcCol: Integer;
begin
  { Clockwise:         source (x, y) -> destination (H-1-y, x)
    Counter-clockwise: source (x, y) -> destination (y, W-1-x) }
  NW := F.Height;
  NH := F.Width;
  GetMem(NewData, PtrUInt(NW) * PtrUInt(NH));
  Row0 := 0;
  while Row0 < NH do
  begin
    RowCount := Min(BLOCK_ROWS, NH - Row0);
    for SY := 0 to F.Height - 1 do
    begin
      SrcRow := F.Data + PtrInt(SY) * F.Width;
      if Clockwise then
      begin
        DstCell := NewData + PtrInt(Row0) * NW + (F.Height - 1 - SY);
        SrcCol := Row0;
        for K := 0 to RowCount - 1 do
        begin
          DstCell^ := SrcRow[SrcCol + K];
          Inc(DstCell, NW);
        end;
      end
      else
      begin
        DstCell := NewData + PtrInt(Row0) * NW + SY;
        SrcCol := F.Width - 1 - Row0;
        for K := 0 to RowCount - 1 do
        begin
          DstCell^ := SrcRow[SrcCol - K];
          Inc(DstCell, NW);
        end;
      end;
    end;
    Inc(Row0, RowCount);
  end;
  FreeMem(F.Data);
  F.Data := NewData;
  F.Width := NW;
  F.Height := NH;
end;

procedure MirrorRows(var F: TGrayFrame);
var
  X, Y: Integer;
  A, B: PByte;
  T: Byte;
begin
  for Y := 0 to F.Height - 1 do
  begin
    A := F.Data + PtrInt(Y) * F.Width;
    B := A + F.Width - 1;
    for X := 0 to F.Width div 2 - 1 do
    begin
      T := A^; A^ := B^; B^ := T;
      Inc(A);
      Dec(B);
    end;
  end;
end;

procedure SwapRows(var F: TGrayFrame);
var
  Y: Integer;
  Tmp, A, B: PByte;
begin
  if F.Height < 2 then Exit;
  GetMem(Tmp, F.Width);
  try
    for Y := 0 to F.Height div 2 - 1 do
    begin
      A := F.Data + PtrInt(Y) * F.Width;
      B := F.Data + PtrInt(F.Height - 1 - Y) * F.Width;
      Move(A^, Tmp^, F.Width);
      Move(B^, A^, F.Width);
      Move(Tmp^, B^, F.Width);
    end;
  finally
    FreeMem(Tmp);
  end;
end;

procedure GrayOrient(var F: TGrayFrame; Rotation: Integer; FlipH, FlipV: Boolean);
begin
  if F.Data = nil then Exit;
  case Rotation of
    90:  RotateQuarter(F, True);
    180:
      begin
        { Two clockwise quarter turns = mirror both ways. }
        MirrorRows(F);
        SwapRows(F);
      end;
    270: RotateQuarter(F, False);
  end;
  if FlipH then MirrorRows(F);
  if FlipV then SwapRows(F);
end;

procedure GrayNegative(var F: TGrayFrame);
var
  I, N: PtrInt;
  P: PByte;
begin
  if F.Data = nil then Exit;
  P := F.Data;
  N := PtrInt(F.Width) * F.Height;
  for I := 0 to N - 1 do
  begin
    P^ := 255 - P^;
    Inc(P);
  end;
end;

procedure GraySharpen(var F: TGrayFrame; Mode, Amount: Integer);
var
  Src, Up, Mid, Down, Dst: PByte;
  X, Y, Sum, C, V: Integer;
  Strength, Blur, Center: Double;
  Size: PtrUInt;
begin
  if (F.Data = nil) or (F.Width < 3) or (F.Height < 3) then Exit;
  Amount := Max(0, Min(100, Amount));
  if Amount <= 0 then Exit;

  case Mode of
    1: Strength := 0.45 + Amount / 70.0;   // unsharp
    2: Strength := 0.65 + Amount / 48.0;   // text crisp
    3: Strength := 0.90 + Amount / 36.0;   // high-pass strong
  else
    Strength := 0.25 + Amount / 120.0;     // soft
  end;

  Size := PtrUInt(F.Width) * PtrUInt(F.Height);
  GetMem(Src, Size);
  try
    Move(F.Data^, Src^, Size);
    { The outermost rows and columns keep their original values. }
    for Y := 1 to F.Height - 2 do
    begin
      Up := Src + PtrInt(Y - 1) * F.Width;
      Mid := Up + F.Width;
      Down := Mid + F.Width;
      Dst := F.Data + PtrInt(Y) * F.Width;
      for X := 1 to F.Width - 2 do
      begin
        C := Mid[X];
        Sum := Up[X - 1] + Up[X] + Up[X + 1] +
               Mid[X - 1] + C + Mid[X + 1] +
               Down[X - 1] + Down[X] + Down[X + 1];
        if Sum <> 9 * C then
        begin
          { Keep every step in Double, exactly like the BGRA filter, so both
            paths round the same way. }
          Blur := Sum;
          Blur := Blur / 9.0;
          Center := C;
          V := Round(Center + (Center - Blur) * Strength);
          if V < 0 then V := 0
          else if V > 255 then V := 255;
          Dst[X] := V;
        end;
      end;
    end;
  finally
    FreeMem(Src);
  end;
end;

end.
