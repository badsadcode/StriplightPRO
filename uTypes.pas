unit uTypes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  DEFAULT_JPG_QUALITY      = 100;
  DEFAULT_PREVIEW_DOWNSCALE = 16;
  DEFAULT_STRIP_DIGITS     = 9;
  EXPORT_ENCODER_BUILTIN   = 0;
  EXPORT_ENCODER_TURBOJPEG = 1;

  // Frame overlay colours (TColor = BGR in LCL on Windows)
  COL_FRAME_NORMAL    = $0000CC00;  // Green
  COL_FRAME_ABNORMAL  = $000000CC;  // Red
  COL_FRAME_MARKER    = $0000CCCC;  // Yellow
  COL_FRAME_SELECTED  = $00CCCC00;  // Cyan
  COL_FRAME_SUGGESTED = $00CC00CC;  // Magenta
  COL_FRAME_PERFRAME  = $000080FF;  // Orange
  COL_FRAME_EXPORTED  = $00FF9900;  // Blue

type
  { TFrameRecord – one detected / manually‑placed frame }
  TFrameRecord = record
    Index            : Integer;  // Sequential 0‑based index
    LeadEdge         : Int64;    // Top edge in global line coords (full‑res)
    TrailEdge        : Int64;    // Bottom edge in global line coords (full‑res)
    LeftEdge         : Integer;  // Left crop edge in full‑res pixels
    RightEdge        : Integer;  // Right crop edge in full‑res pixels
    IsMarker         : Boolean;  // Yellow folder‑start marker
    IsSelected       : Boolean;  // Currently selected in UI
    IsOversized      : Boolean;  // Exceeds average size threshold
    IsUndersized     : Boolean;  // Below average size threshold
    IsSuggested      : Boolean;  // Auto‑suggested yellow marker (dashed)
    IsExported       : Boolean;  // Export completed in current session
    PerFrameBrightness: Integer; // Quantum-compatible per-frame override; -1 = use global
    PerFrameContrast  : Integer;
    PerFrameGamma     : Integer;
    CustomBrightness : Integer;  // Per‑frame override; ‑1 = use global
    CustomContrast   : Integer;
    CustomGamma      : Integer;
    Rotation         : Integer;  // 0, 90, 180, 270
    FlipH            : Boolean;
    FlipV            : Boolean;
    Negative         : Boolean;  // invert colours at export
    HasOverride      : Boolean;  // True = this frame uses its own per-frame settings
  end;
  PFrameRecord = ^TFrameRecord;

  TFrameList = array of TFrameRecord;

  { TRollData – parsed metadata from one IDF file }
  TRollData = record
    RollName         : String;
    RollID           : String;
    RollNumber       : String;
    BasePath         : String;   // Directory containing the IDF file (trailing sep)
    PreviewBasePath  : String;   // Directory used for previews; may point to a local cache
    PreviewSourceBasePath: String; // Original preview directory base from the IDF
    StripFolder      : String;   // e.g. 'strips'
    PreviewFolder    : String;   // e.g. 'previews'
    PreviewSourceFolder: String; // Original preview folder from the IDF
    StripPrefix      : String;   // e.g. 'strip'
    PreviewPrefix    : String;   // usually same as StripPrefix
    StripDigits      : Integer;  // zero‑pad width for filenames
    StripCount       : Integer;  // total strips in roll
    LengthLines      : Integer;  // full‑res strip height in pixels
    WidthPixels      : Integer;  // full‑res strip width in pixels
    StripPixels      : Integer;  // active scan width (may be < WidthPixels)
    PreviewDownScale : Integer;  // divisor: full / preview
    DPI              : Integer;
    JpgQuality       : Integer;
    SoftwareContrast : Integer;
    SoftwareBrightness: Integer;
    SoftwareGamma    : Integer;
    StriplightAdjustMethod: Integer;
    StriplightAdjustFlags : Integer;
    StriplightAdjustContrast: Integer;
    StriplightAdjustBrightness: Integer;
    StriplightAdjustGamma: Integer;
    StriplightSharpness: Integer;
    StriplightSharpnessMode: Integer;
    StriplightExportNamingMode: Integer; // 0 = Quantum folders, 1 = archive list
    StriplightArchiveList: String;
    StriplightExportGrayscale: Boolean;
    StriplightExportProgressive: Boolean;
    StriplightExportEncoder: Integer;
    DetectionThreshold: Integer;
    DetectMinWidth   : Integer;
    DetectMinLength  : Integer;
    PreviewCacheEnabled: Boolean;
    Loaded           : Boolean;
  end;

  { TFrameStats – computed after loading frames }
  TFrameStats = record
    MedianHeight      : Int64;
    MedianWidth       : Integer;
    AvgHeight         : Int64;
    AvgWidth          : Integer;
    OversizeThreshold : Double;  // fraction of median (e.g. 1.5)
    UndersizeThreshold: Double;  // fraction of median (e.g. 0.5)
  end;

{ Initialisation helpers }
procedure InitRollData(out ARoll: TRollData);
procedure InitFrameRecord(out AFrame: TFrameRecord; AIndex: Integer);

{ Frame geometry helpers }
function FrameHeight(const F: TFrameRecord): Int64;
function FrameWidth(const F: TFrameRecord): Integer;
function FrameLeadStrip(const F: TFrameRecord; LengthLines: Integer): Integer;
function FrameTrailStrip(const F: TFrameRecord; LengthLines: Integer): Integer;
function FrameSpansStrips(const F: TFrameRecord; LengthLines: Integer): Boolean;
procedure SortFramesByPosition(var Frames: TFrameList);

{ Statistics }
procedure CalculateFrameStats(const Frames: TFrameList; out Stats: TFrameStats);
procedure MarkOversizedUndersized(var Frames: TFrameList; const Stats: TFrameStats);

{ Path helpers }
function ZeroPadInt(Value, Digits: Integer): String;
function PreviewFilePath(const Roll: TRollData; StripIndex: Integer): String;
function StripFilePath(const Roll: TRollData; StripIndex: Integer): String;

implementation

{ ---------- Initialisation ---------- }

procedure InitRollData(out ARoll: TRollData);
begin
  FillChar(ARoll, SizeOf(ARoll), 0);
  ARoll.PreviewDownScale := DEFAULT_PREVIEW_DOWNSCALE;
  ARoll.JpgQuality       := DEFAULT_JPG_QUALITY;
  ARoll.SoftwareContrast := 0;
  ARoll.SoftwareBrightness := 0;
  ARoll.SoftwareGamma    := 0;
  ARoll.StriplightAdjustMethod := 0;
  ARoll.StriplightAdjustFlags := 0;
  ARoll.StriplightAdjustContrast := 0;
  ARoll.StriplightAdjustBrightness := 0;
  ARoll.StriplightAdjustGamma := 100;
  ARoll.StriplightSharpness := 0;
  ARoll.StriplightSharpnessMode := 0;
  ARoll.StriplightExportNamingMode := 0;
  ARoll.StriplightArchiveList := '';
  ARoll.StriplightExportGrayscale := True;
  ARoll.StriplightExportProgressive := False;
  ARoll.StriplightExportEncoder := EXPORT_ENCODER_BUILTIN;
  ARoll.DetectionThreshold := 100;
  ARoll.DetectMinWidth   := 252;
  ARoll.DetectMinLength  := 252;
  ARoll.StripDigits      := DEFAULT_STRIP_DIGITS;
  ARoll.StripPrefix      := 'strip';
  ARoll.PreviewPrefix    := 'preview';
  ARoll.LengthLines      := 4096;
  ARoll.WidthPixels      := 4916;
  ARoll.Loaded           := False;
end;

procedure InitFrameRecord(out AFrame: TFrameRecord; AIndex: Integer);
begin
  FillChar(AFrame, SizeOf(AFrame), 0);
  AFrame.Index            := AIndex;
  AFrame.PerFrameBrightness := -1;
  AFrame.PerFrameContrast   := -1;
  AFrame.PerFrameGamma      := -1;
  AFrame.CustomBrightness := -1;
  AFrame.CustomContrast   := -1;
  AFrame.CustomGamma      := -1;
end;

{ ---------- Frame geometry ---------- }

function FrameHeight(const F: TFrameRecord): Int64;
begin
  Result := F.TrailEdge - F.LeadEdge;
end;

function FrameWidth(const F: TFrameRecord): Integer;
begin
  Result := F.RightEdge - F.LeftEdge;
end;

function FrameLeadStrip(const F: TFrameRecord; LengthLines: Integer): Integer;
begin
  if LengthLines <= 0 then Result := 0
  else Result := Integer(F.LeadEdge div LengthLines);
end;

function FrameTrailStrip(const F: TFrameRecord; LengthLines: Integer): Integer;
begin
  if LengthLines <= 0 then Result := 0
  else Result := Integer(F.TrailEdge div LengthLines);
end;

function FrameSpansStrips(const F: TFrameRecord; LengthLines: Integer): Boolean;
begin
  Result := FrameTrailStrip(F, LengthLines) > FrameLeadStrip(F, LengthLines);
end;

procedure SortFramesByPosition(var Frames: TFrameList);
var
  i, j: Integer;
  Cur: TFrameRecord;
begin
  for i := 1 to High(Frames) do
  begin
    Cur := Frames[i];
    j := i - 1;
    while (j >= 0) and
          ((Frames[j].LeadEdge > Cur.LeadEdge) or
           ((Frames[j].LeadEdge = Cur.LeadEdge) and
            (Frames[j].TrailEdge > Cur.TrailEdge))) do
    begin
      Frames[j + 1] := Frames[j];
      Dec(j);
    end;
    Frames[j + 1] := Cur;
  end;

  for i := 0 to High(Frames) do
    Frames[i].Index := i;
end;

{ ---------- Statistics ---------- }

function CompareInt64(const A, B: Int64): Integer;
begin
  if A < B then Result := -1
  else if A > B then Result := 1
  else Result := 0;
end;

procedure QuickSortInt64(var A: array of Int64; Lo, Hi: Integer);
var
  Pivot, Tmp: Int64;
  i, j: Integer;
begin
  i := Lo; j := Hi;
  Pivot := A[(Lo + Hi) div 2];
  while i <= j do
  begin
    while A[i] < Pivot do Inc(i);
    while A[j] > Pivot do Dec(j);
    if i <= j then
    begin
      Tmp := A[i]; A[i] := A[j]; A[j] := Tmp;
      Inc(i); Dec(j);
    end;
  end;
  if Lo < j then QuickSortInt64(A, Lo, j);
  if i < Hi then QuickSortInt64(A, i, Hi);
end;

procedure CalculateFrameStats(const Frames: TFrameList; out Stats: TFrameStats);
var
  n, i: Integer;
  Heights: array of Int64;
  TotalH, TotalW: Int64;
begin
  FillChar(Stats, SizeOf(Stats), 0);
  Stats.OversizeThreshold  := 1.5;
  Stats.UndersizeThreshold := 0.5;

  n := Length(Frames);
  if n = 0 then Exit;

  SetLength(Heights, n);
  TotalH := 0;
  TotalW := 0;
  for i := 0 to n - 1 do
  begin
    Heights[i] := FrameHeight(Frames[i]);
    TotalH := TotalH + Heights[i];
    TotalW := TotalW + FrameWidth(Frames[i]);
  end;

  Stats.AvgHeight := TotalH div n;
  Stats.AvgWidth  := Integer(TotalW div n);

  // Compute true median via sort
  QuickSortInt64(Heights, 0, n - 1);
  if (n mod 2) = 1 then
    Stats.MedianHeight := Heights[n div 2]
  else
    Stats.MedianHeight := (Heights[n div 2 - 1] + Heights[n div 2]) div 2;

  Stats.MedianWidth := Stats.AvgWidth;  // width median simplified
end;

procedure MarkOversizedUndersized(var Frames: TFrameList; const Stats: TFrameStats);
var
  i: Integer;
  H: Int64;
  OverH, UnderH: Int64;
begin
  if Stats.MedianHeight = 0 then Exit;
  OverH  := Round(Stats.MedianHeight * Stats.OversizeThreshold);
  UnderH := Round(Stats.MedianHeight * Stats.UndersizeThreshold);
  for i := 0 to High(Frames) do
  begin
    H := FrameHeight(Frames[i]);
    Frames[i].IsOversized  := H > OverH;
    Frames[i].IsUndersized := (H < UnderH) and (H > 0);
  end;
end;

{ ---------- Path helpers ---------- }

function ZeroPadInt(Value, Digits: Integer): String;
begin
  Result := IntToStr(Value);
  while Length(Result) < Digits do
    Result := '0' + Result;
end;

function PreviewFilePath(const Roll: TRollData; StripIndex: Integer): String;
var
  CachePath, SourceBase, SourceFolder: String;
  InStream, OutStream: TFileStream;
begin
  { Files on disk are 1-based (preview000000001.jpg .. previewNNNNNNNNN.jpg) }
  CachePath := IncludeTrailingPathDelimiter(Roll.PreviewBasePath)
          + Roll.PreviewFolder
          + PathDelim
          + Roll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, Roll.StripDigits)
          + '.jpg';
  if Roll.PreviewCacheEnabled and FileExists(CachePath) then
    Exit(CachePath);

  SourceBase := Roll.PreviewSourceBasePath;
  if SourceBase = '' then SourceBase := Roll.BasePath;
  SourceFolder := Roll.PreviewSourceFolder;
  if SourceFolder = '' then SourceFolder := Roll.PreviewFolder;
  Result := IncludeTrailingPathDelimiter(SourceBase)
          + SourceFolder
          + PathDelim
          + Roll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, Roll.StripDigits)
          + '.jpg';
  if Roll.PreviewCacheEnabled and FileExists(Result) then
  begin
    try
      ForceDirectories(ExtractFilePath(CachePath));
      InStream := TFileStream.Create(Result, fmOpenRead or fmShareDenyNone);
      try
        OutStream := TFileStream.Create(CachePath, fmCreate);
        try
          OutStream.CopyFrom(InStream, 0);
        finally
          OutStream.Free;
        end;
      finally
        InStream.Free;
      end;
      if FileExists(CachePath) then
        Result := CachePath;
    except
      { Fall back to the original preview path if local caching fails. }
    end;
  end;
end;

function StripFilePath(const Roll: TRollData; StripIndex: Integer): String;
begin
  { Files on disk are 1-based (strip000000001.jpg .. stripNNNNNNNNN.jpg) }
  Result := IncludeTrailingPathDelimiter(Roll.BasePath)
          + Roll.StripFolder
          + PathDelim
          + Roll.StripPrefix
          + ZeroPadInt(StripIndex + 1, Roll.StripDigits)
          + '.jpg';
end;

end.
