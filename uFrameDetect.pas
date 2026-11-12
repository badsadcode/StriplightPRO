unit uFrameDetect;

{$mode objfpc}{$H+}

{ Preview-based frame detection.

  The scanner writes preview strips that are lossless enough for geometry work.
  Detection applies the user's image-adjustment sliders in memory, then finds
  bright bands against the dark film background. Original strip files are never
  modified.
}

interface

uses
  SysUtils, Math, BGRABitmap, BGRABitmapTypes, uTypes;

type
  TDetectOptions = record
    StripFrom       : Integer;  // 0-based, inclusive
    StripTo         : Integer;  // 0-based, inclusive
    MinWidthPx      : Integer;  // full-res pixels
    MinHeightPx     : Integer;  // full-res pixels
    Brightness      : Integer;  // -100..100
    Contrast        : Integer;  // -100..100
    Gamma           : Integer;  // 10..300, where 100 = neutral
    Threshold       : Integer;  // 0..255 after adjustment
    MergeAcrossGaps : Integer;  // full-res line gap allowed between runs
    DetectLeftInsetPx : Integer; // full-res pixels ignored from preview X start
    DetectRightInsetPx: Integer; // full-res pixels ignored from preview X end
  end;

  TDetectStats = record
    StripsRead    : Integer;
    StripsMissing : Integer;
    FramesFound   : Integer;
    CacheCopied   : Integer;
  end;

  TDetectProgressEvent = function(CurrentStrip, TotalStrips: Integer;
                                  const Stats: TDetectStats;
                                  const Frames: TFrameList): Boolean of object;
  TPreviewPathEvent = function(StripIndex: Integer; out Path: String;
                               out CachedNow: Boolean): Boolean of object;

function DetectFramesFromPreviews(const Roll: TRollData;
                                  const Options: TDetectOptions;
                                  out Frames: TFrameList;
                                  out Stats: TDetectStats;
                                  OnProgress: TDetectProgressEvent = nil;
                                  OnPreviewPath: TPreviewPathEvent = nil): Boolean;

implementation

function ClampInt(Value, Lo, Hi: Integer): Integer;
begin
  if Value < Lo then Result := Lo
  else if Value > Hi then Result := Hi
  else Result := Value;
end;

function AdjustLum(Lum: Integer; const Options: TDetectOptions): Integer;
var
  V, C, G: Double;
begin
  V := Lum / 255.0;

  G := Options.Gamma / 100.0;
  if G <= 0.01 then G := 1.0;
  V := Power(V, 1.0 / G);

  C := (100.0 + Options.Contrast) / 100.0;
  V := ((V - 0.5) * C) + 0.5;
  V := V + (Options.Brightness / 100.0);

  Result := ClampInt(Round(V * 255.0), 0, 255);
end;

function PixelLum(const P: TBGRAPixel): Integer;
begin
  Result := (Integer(P.red) * 30 + Integer(P.green) * 59 + Integer(P.blue) * 11) div 100;
end;

procedure AppendFrame(var Frames: TFrameList; const Frame: TFrameRecord);
begin
  SetLength(Frames, Length(Frames) + 1);
  Frames[High(Frames)] := Frame;
  Frames[High(Frames)].Index := High(Frames);
end;

function RangesOverlapEnough(A1, A2, B1, B2: Integer): Boolean;
var
  Overlap, Narrowest: Integer;
begin
  Overlap := Min(A2, B2) - Max(A1, B1);
  Narrowest := Min(A2 - A1, B2 - B1);
  Result := (Overlap > 0) and ((Narrowest <= 0) or (Overlap >= Narrowest div 3));
end;

procedure AppendOrMergeFrame(var Frames: TFrameList; const Frame: TFrameRecord;
                             GapLines: Integer);
var
  Last: Integer;
begin
  Last := High(Frames);
  if (Last >= 0) and
     (Frame.LeadEdge - Frames[Last].TrailEdge <= GapLines) and
     RangesOverlapEnough(Frames[Last].LeftEdge, Frames[Last].RightEdge,
                         Frame.LeftEdge, Frame.RightEdge) then
  begin
    Frames[Last].TrailEdge := Max(Frames[Last].TrailEdge, Frame.TrailEdge);
    Frames[Last].LeftEdge  := Min(Frames[Last].LeftEdge, Frame.LeftEdge);
    Frames[Last].RightEdge := Max(Frames[Last].RightEdge, Frame.RightEdge);
  end
  else
    AppendFrame(Frames, Frame);
end;

function DetectFramesFromPreviews(const Roll: TRollData;
                                  const Options: TDetectOptions;
                                  out Frames: TFrameList;
                                  out Stats: TDetectStats;
                                  OnProgress: TDetectProgressEvent;
                                  OnPreviewPath: TPreviewPathEvent): Boolean;
var
  StripIdx, Y, X: Integer;
  StripFrom, StripTo: Integer;
  MinWPrev, MinHPrev: Integer;
  Threshold: Integer;
  Path: String;
  Bmp: TBGRABitmap;
  P: PBGRAPixel;
  BrightCount, RowMinX, RowMaxX: Integer;
  ScanMinX, ScanMaxX: Integer;
  InRun: Boolean;
  RunStartY, RunEndY, RunMinX, RunMaxX: Integer;
  Frame: TFrameRecord;
  TotalStrips, CurStrip: Integer;
  CachedNow: Boolean;
  LumLUT: array[0..255] of Integer;

  procedure FinishRun;
  var
    H: Integer;
  begin
    if not InRun then Exit;
    H := RunEndY - RunStartY + 1;
    if H >= MinHPrev then
    begin
      InitFrameRecord(Frame, Length(Frames));
      Frame.LeadEdge  := Int64(StripIdx) * Roll.LengthLines
                       + Int64(RunStartY) * Roll.PreviewDownScale;
      Frame.TrailEdge := Int64(StripIdx) * Roll.LengthLines
                       + Int64(RunEndY + 1) * Roll.PreviewDownScale;
      Frame.LeftEdge  := ClampInt(RunMinX * Roll.PreviewDownScale, 0, Roll.WidthPixels);
      Frame.RightEdge := ClampInt((RunMaxX + 1) * Roll.PreviewDownScale, 0, Roll.WidthPixels);

      if Frame.TrailEdge > Int64(StripIdx + 1) * Roll.LengthLines then
        Frame.TrailEdge := Int64(StripIdx + 1) * Roll.LengthLines;
      if (Frame.TrailEdge > Frame.LeadEdge) and (Frame.RightEdge > Frame.LeftEdge) then
        AppendOrMergeFrame(Frames, Frame, Options.MergeAcrossGaps);
    end;
    InRun := False;
  end;

begin
  SetLength(Frames, 0);
  FillChar(Stats, SizeOf(Stats), 0);
  Result := False;

  if not Roll.Loaded then Exit;
  if Roll.StripCount <= 0 then Exit;

  StripFrom := ClampInt(Options.StripFrom, 0, Roll.StripCount - 1);
  StripTo   := ClampInt(Options.StripTo,   0, Roll.StripCount - 1);
  if StripTo < StripFrom then Exit;

  MinWPrev := Max(1, Options.MinWidthPx div Max(1, Roll.PreviewDownScale));
  MinHPrev := Max(1, Options.MinHeightPx div Max(1, Roll.PreviewDownScale));
  Threshold := ClampInt(Options.Threshold, 1, 254);
  TotalStrips := StripTo - StripFrom + 1;
  CurStrip := 0;
  for X := 0 to 255 do
    LumLUT[X] := AdjustLum(X, Options);

  for StripIdx := StripFrom to StripTo do
  begin
    Inc(CurStrip);
    CachedNow := False;
    if Assigned(OnPreviewPath) then
    begin
      if not OnPreviewPath(StripIdx, Path, CachedNow) then
      begin
        Inc(Stats.StripsMissing);
        Stats.FramesFound := Length(Frames);
        if Assigned(OnProgress) and not OnProgress(CurStrip, TotalStrips, Stats, Frames) then Break;
        Continue;
      end;
      if CachedNow then Inc(Stats.CacheCopied);
    end
    else
      Path := PreviewFilePath(Roll, StripIdx);
    if not FileExists(Path) then
    begin
      Inc(Stats.StripsMissing);
      Stats.FramesFound := Length(Frames);
      if Assigned(OnProgress) and not OnProgress(CurStrip, TotalStrips, Stats, Frames) then Break;
      Continue;
    end;

    Bmp := nil;
    try
      Bmp := TBGRABitmap.Create(Path);
      Inc(Stats.StripsRead);
      InRun := False;
      ScanMinX := ClampInt(Options.DetectLeftInsetPx div Max(1, Roll.PreviewDownScale),
                           0, Max(0, Bmp.Width - 1));
      ScanMaxX := ClampInt(Bmp.Width - 1 -
                           (Options.DetectRightInsetPx div Max(1, Roll.PreviewDownScale)),
                           0, Max(0, Bmp.Width - 1));
      if ScanMaxX < ScanMinX then
      begin
        FinishRun;
        Continue;
      end;

      for Y := 0 to Bmp.Height - 1 do
      begin
        BrightCount := 0;
        RowMinX := Bmp.Width;
        RowMaxX := -1;

        P := Bmp.ScanLine[Y];
        Inc(P, ScanMinX);
        for X := ScanMinX to ScanMaxX do
        begin
          if LumLUT[PixelLum(P^)] >= Threshold then
          begin
            Inc(BrightCount);
            if X < RowMinX then RowMinX := X;
            if X > RowMaxX then RowMaxX := X;
          end;
          Inc(P);
        end;

        if (BrightCount >= MinWPrev) and ((RowMaxX - RowMinX + 1) >= MinWPrev) then
        begin
          if not InRun then
          begin
            InRun := True;
            RunStartY := Y;
            RunMinX := RowMinX;
            RunMaxX := RowMaxX;
          end
          else
          begin
            RunMinX := Min(RunMinX, RowMinX);
            RunMaxX := Max(RunMaxX, RowMaxX);
          end;
          RunEndY := Y;
        end
        else
          FinishRun;
      end;

      FinishRun;
    finally
      Bmp.Free;
    end;

    Stats.FramesFound := Length(Frames);
    if Assigned(OnProgress) and not OnProgress(CurStrip, TotalStrips, Stats, Frames) then Break;
  end;

  Stats.FramesFound := Length(Frames);
  Result := Stats.StripsRead > 0;
end;

end.
