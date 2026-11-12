unit uQPF;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, IniFiles, DOM, XMLRead, uTypes;

function QPFPathForIDF(const IDFPath: String): String;
function SLFPathForIDF(const IDFPath: String): String;

function SaveQPF(const FileName, IDFPath: String; const Roll: TRollData;
                 const Frames: TFrameList): Boolean;
function SaveSLF(const FileName, IDFPath: String; const Roll: TRollData;
                 const Frames: TFrameList): Boolean;

function LoadQPF(const FileName: String; out Frames: TFrameList): Boolean;
function LoadSLF(const FileName: String; out Frames: TFrameList): Boolean;
function LoadQPFProject(const FileName: String; out Roll: TRollData;
                        out Frames: TFrameList): Boolean;
function LoadSLFProject(const FileName: String; out Roll: TRollData;
                        out Frames: TFrameList): Boolean;
function SLFSourceIDFPath(const FileName: String): String;

implementation

function PerFrameFlipValue(const Frame: TFrameRecord): Integer;
begin
  Result := 0;
  if Frame.FlipH then
    Result := Result or 1;
  if Frame.FlipV then
    Result := Result or 2;
end;

function QPFPathForIDF(const IDFPath: String): String;
begin
  Result := ChangeFileExt(IDFPath, '.qpf');
end;

function SLFPathForIDF(const IDFPath: String): String;
begin
  Result := ChangeFileExt(IDFPath, '.slf');
end;

function XmlEscape(const S: String): String;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
      '''': Result := Result + '&apos;';
    else
      Result := Result + S[i];
    end;
end;

function BoolText(Value: Boolean): String;
begin
  if Value then Result := 'True' else Result := 'False';
end;

function EncodeSLFText(const S: String): String;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, #13#10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\n', [rfReplaceAll]);
end;

function DecodeSLFText(const S: String): String;
begin
  Result := S;
  { Accept normal escapes and values passed through one extra escaping layer. }
  Result := StringReplace(Result, '\\r\\n', LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, '\\n', LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, '\r\n', LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, '\n', LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, '\r', LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, '\\', '\', [rfReplaceAll]);
end;

function IntText(Value: Boolean): String;
begin
  if Value then Result := '1' else Result := '0';
end;

procedure StreamLine(Stream: TStream; const S: String);
var
  Line: String;
begin
  Line := S + LineEnding;
  if Line <> '' then
    Stream.WriteBuffer(Pointer(Line)^, Length(Line));
end;

function AttrStr(Node: TDOMNode; const Name: String; const Default: String = ''): String;
var
  A: TDOMNode;
begin
  Result := Default;
  if (Node = nil) or (Node.Attributes = nil) then Exit;
  A := Node.Attributes.GetNamedItem(UTF8Decode(Name));
  if A <> nil then
    Result := UTF8Encode(A.NodeValue);
end;

function AttrInt(Node: TDOMNode; const Name: String; Default: Integer = 0): Integer;
begin
  Result := StrToIntDef(AttrStr(Node, Name), Default);
end;

function AttrInt64(Node: TDOMNode; const Name: String; Default: Int64 = 0): Int64;
begin
  Result := StrToInt64Def(AttrStr(Node, Name), Default);
end;

function AttrBool(Node: TDOMNode; const Name: String; Default: Boolean = False): Boolean;
var
  S: String;
begin
  S := LowerCase(AttrStr(Node, Name, ''));
  if (S = 'true') or (S = '1') or (S = 'yes') then
    Result := True
  else if (S = 'false') or (S = '0') or (S = 'no') then
    Result := False
  else
    Result := Default;
end;

function IsPersistableFrame(const Frame: TFrameRecord): Boolean;
begin
  Result := (Frame.TrailEdge > Frame.LeadEdge) and
            (Frame.RightEdge > Frame.LeftEdge);
end;

function FindChild(Node: TDOMNode; const Name: String): TDOMNode;
var
  i: Integer;
  Child: TDOMNode;
begin
  Result := nil;
  if Node = nil then Exit;
  for i := 0 to Integer(Node.ChildNodes.Count) - 1 do
  begin
    Child := Node.ChildNodes.Item[i];
    if UTF8Encode(Child.NodeName) = Name then
      Exit(Child);
  end;
end;

function FindScannerSettings(RollNode: TDOMNode; const IDValue: String): TDOMNode;
var
  i: Integer;
  Child, FirstScanner: TDOMNode;
begin
  Result := nil;
  FirstScanner := nil;
  if RollNode = nil then Exit;
  for i := 0 to Integer(RollNode.ChildNodes.Count) - 1 do
  begin
    Child := RollNode.ChildNodes.Item[i];
    if UTF8Encode(Child.NodeName) <> 'ScannerSettings' then Continue;
    if FirstScanner = nil then FirstScanner := Child;
    if SameText(AttrStr(Child, 'ID'), IDValue) then
      Exit(Child);
  end;
  if Result = nil then
    Result := FirstScanner;
end;

function LoadFramesFromDetection(DetectionNode: TDOMNode; out Frames: TFrameList): Boolean;
var
  i, Count: Integer;
  Child: TDOMNode;
  Frame: TFrameRecord;
  FlipValue: Integer;
begin
  Result := False;
  Frames := nil;
  if DetectionNode = nil then Exit;

  SetLength(Frames, 0);
  Count := 0;
  for i := 0 to Integer(DetectionNode.ChildNodes.Count) - 1 do
  begin
    Child := DetectionNode.ChildNodes.Item[i];
    if UTF8Encode(Child.NodeName) <> 'Frame' then Continue;
    InitFrameRecord(Frame, Count);
    Frame.LeadEdge         := AttrInt64(Child, 'LeadEdge', 0);
    Frame.TrailEdge        := AttrInt64(Child, 'TrailEdge', 0);
    Frame.LeftEdge         := AttrInt(Child, 'LeftEdge', 0);
    Frame.RightEdge        := AttrInt(Child, 'RightEdge', 0);
    Frame.IsMarker         := AttrBool(Child, 'IsMarker', False);
    Frame.IsSuggested      := AttrBool(Child, 'IsSuggested', False);
    Frame.PerFrameBrightness := AttrInt(Child, 'PerFrameBrightness', -1);
    Frame.PerFrameContrast   := AttrInt(Child, 'PerFrameContrast', -1);
    Frame.PerFrameGamma      := AttrInt(Child, 'PerFrameGamma', -1);
    Frame.CustomBrightness := AttrInt(Child, 'CustomBrightness', -1);
    Frame.CustomContrast   := AttrInt(Child, 'CustomContrast', -1);
    Frame.CustomGamma      := AttrInt(Child, 'CustomGamma', -1);
    Frame.Rotation         := AttrInt(Child, 'PerFrameRotate',
                                      AttrInt(Child, 'Rotation', 0));
    FlipValue              := AttrInt(Child, 'PerFrameFlip', 0);
    Frame.FlipH            := ((FlipValue and 1) <> 0) or AttrBool(Child, 'FlipH', False);
    Frame.FlipV            := ((FlipValue and 2) <> 0) or AttrBool(Child, 'FlipV', False);
    Frame.Negative         := AttrBool(Child, 'Negative', False);
    Frame.HasOverride      := AttrBool(Child, 'HasOverride', False) or
                              (Frame.Rotation <> 0) or (FlipValue <> 0) or
                              (Frame.PerFrameBrightness <> -1) or
                              (Frame.PerFrameContrast <> -1) or
                              (Frame.PerFrameGamma <> -1);
    if not IsPersistableFrame(Frame) then
      Continue;
    SetLength(Frames, Count + 1);
    Frames[Count] := Frame;
    Frames[Count].Index := Count;
    Inc(Count);
  end;
  Result := Count > 0;
end;

function LoadFramesFromRollXML(const FileName: String; out Frames: TFrameList): Boolean;
var
  Doc: TXMLDocument;
  RollNode, ScannerNode, DetectionNode, StriplightNode: TDOMNode;
begin
  Result := False;
  Frames := nil;
  Doc := nil;
  try
    ReadXMLFile(Doc, FileName);
    RollNode := Doc.DocumentElement;
    if (RollNode = nil) or (UTF8Encode(RollNode.NodeName) <> 'Roll') then
      Exit;

    ScannerNode := FindScannerSettings(RollNode, 'QP');
    DetectionNode := FindChild(ScannerNode, 'DetectionSettings');
    Result := LoadFramesFromDetection(DetectionNode, Frames);
  except
    Result := False;
    Frames := nil;
  end;
  if Doc <> nil then Doc.Free;
end;

function SourceIDFFromRollXML(const FileName: String): String;
var
  Doc: TXMLDocument;
  RollNode, Node: TDOMNode;
begin
  Result := '';
  Doc := nil;
  try
    ReadXMLFile(Doc, FileName);
    RollNode := Doc.DocumentElement;
    if (RollNode = nil) or (UTF8Encode(RollNode.NodeName) <> 'Roll') then
      Exit;
    Node := FindChild(RollNode, 'StriplightSettings');
    Result := AttrStr(Node, 'SourceIDFPath', '');
  except
    Result := '';
  end;
  if Doc <> nil then Doc.Free;
end;

function LoadProjectFromRollXML(const FileName: String; out Roll: TRollData;
  out Frames: TFrameList): Boolean;
var
  Doc: TXMLDocument;
  RollNode, ScannerNode, DetectionNode, StriplightNode: TDOMNode;
begin
  Result := False;
  InitRollData(Roll);
  Frames := nil;
  Doc := nil;
  try
    ReadXMLFile(Doc, FileName);
    RollNode := Doc.DocumentElement;
    if (RollNode = nil) or (UTF8Encode(RollNode.NodeName) <> 'Roll') then
      Exit;

    ScannerNode := FindScannerSettings(RollNode, '1');
    if ScannerNode = nil then
      ScannerNode := FindScannerSettings(RollNode, 'QP');
    if ScannerNode = nil then
      Exit;

    Roll.RollName   := AttrStr(RollNode, 'RollName');
    Roll.RollNumber := AttrStr(RollNode, 'RollNumber');
    Roll.RollID     := AttrStr(RollNode, 'RollID');
    Roll.BasePath   := IncludeTrailingPathDelimiter(ExtractFilePath(FileName));
    Roll.PreviewBasePath := Roll.BasePath;
    Roll.PreviewSourceBasePath := Roll.BasePath;
    if (Roll.RollName = '') or (LowerCase(Roll.RollName) = 'none') then
      Roll.RollName := ChangeFileExt(ExtractFileName(FileName), '');

    Roll.StripCount       := AttrInt(ScannerNode, 'StripCount', 0);
    Roll.DPI              := AttrInt(ScannerNode, 'DPI', 300);
    Roll.WidthPixels      := AttrInt(ScannerNode, 'WidthPixels', 4916);
    Roll.LengthLines      := AttrInt(ScannerNode, 'LengthLines', 4096);
    Roll.PreviewDownScale := AttrInt(ScannerNode, 'StripPreviewDownScale', DEFAULT_PREVIEW_DOWNSCALE);
    Roll.StripFolder      := AttrStr(ScannerNode, 'StripImageFolder', 'strips');
    Roll.PreviewFolder    := AttrStr(ScannerNode, 'StripPreviewImageFolder', 'previews');
    Roll.PreviewSourceFolder := Roll.PreviewFolder;
    Roll.StripPrefix      := AttrStr(ScannerNode, 'StripImageFilePrefix', 'strip');
    Roll.PreviewPrefix    := AttrStr(ScannerNode, 'StripPreviewImageFilePrefix', 'preview');
    Roll.StripDigits      := AttrInt(ScannerNode, 'StripImageFileDigits', DEFAULT_STRIP_DIGITS);
    Roll.StripPixels      := AttrInt(ScannerNode, 'StripPixels', Roll.WidthPixels);
    Roll.JpgQuality       := AttrInt(ScannerNode, 'JpgQuality', DEFAULT_JPG_QUALITY);
    Roll.SoftwareContrast := AttrInt(ScannerNode, 'SoftwareContrast', 0);
    Roll.SoftwareBrightness := AttrInt(ScannerNode, 'SoftwareBrightness', 0);
    Roll.SoftwareGamma    := AttrInt(ScannerNode, 'SoftwareGamma', 0);

    StriplightNode := FindChild(RollNode, 'StriplightSettings');
    if StriplightNode <> nil then
    begin
      Roll.StriplightAdjustMethod := AttrInt(StriplightNode, 'AdjustMethod', Roll.StriplightAdjustMethod);
      Roll.StriplightAdjustFlags := AttrInt(StriplightNode, 'AdjustFlags', Roll.StriplightAdjustFlags);
      Roll.StriplightAdjustContrast := AttrInt(StriplightNode, 'AdjustContrast', Roll.StriplightAdjustContrast);
      Roll.StriplightAdjustBrightness := AttrInt(StriplightNode, 'AdjustBrightness', Roll.StriplightAdjustBrightness);
      Roll.StriplightAdjustGamma := AttrInt(StriplightNode, 'AdjustGamma', Roll.StriplightAdjustGamma);
      Roll.StriplightSharpness := AttrInt(StriplightNode, 'Sharpness', Roll.StriplightSharpness);
      Roll.StriplightSharpnessMode := AttrInt(StriplightNode, 'SharpnessMode', Roll.StriplightSharpnessMode);
      Roll.StriplightExportNamingMode := AttrInt(StriplightNode, 'ExportNamingMode', Roll.StriplightExportNamingMode);
      Roll.StriplightArchiveList := DecodeSLFText(AttrStr(StriplightNode, 'ArchiveList', Roll.StriplightArchiveList));
      Roll.StriplightExportGrayscale := AttrBool(StriplightNode, 'ExportGrayscale', Roll.StriplightExportGrayscale);
      Roll.StriplightExportProgressive := AttrBool(StriplightNode, 'ExportProgressive', Roll.StriplightExportProgressive);
      Roll.StriplightExportEncoder := AttrInt(StriplightNode, 'ExportEncoder', Roll.StriplightExportEncoder);
    end;

    if Roll.PreviewDownScale <= 0 then Roll.PreviewDownScale := DEFAULT_PREVIEW_DOWNSCALE;
    if Roll.LengthLines <= 0 then Roll.LengthLines := 4096;
    if Roll.WidthPixels <= 0 then Roll.WidthPixels := 4916;
    if Roll.StripDigits <= 0 then Roll.StripDigits := DEFAULT_STRIP_DIGITS;
    if Roll.StripPrefix = '' then Roll.StripPrefix := 'strip';
    if Roll.PreviewPrefix = '' then Roll.PreviewPrefix := 'preview';
    if Roll.StripFolder = '' then Roll.StripFolder := 'strips';
    if Roll.PreviewFolder = '' then Roll.PreviewFolder := 'previews';
    if Roll.PreviewSourceFolder = '' then Roll.PreviewSourceFolder := Roll.PreviewFolder;

    ScannerNode := FindScannerSettings(RollNode, 'QP');
    DetectionNode := FindChild(ScannerNode, 'DetectionSettings');
    if DetectionNode <> nil then
    begin
      Roll.DetectionThreshold := AttrInt(DetectionNode, 'DetectionThreshold', 100);
      Roll.DetectMinWidth := AttrInt(DetectionNode, 'DetectMinWidth', 252);
      Roll.DetectMinLength := AttrInt(DetectionNode, 'DetectMinLength', 252);
    end;

    if not LoadFramesFromDetection(DetectionNode, Frames) then
      SetLength(Frames, 0);

    Roll.Loaded := True;
    Result := True;
  except
    Result := False;
    Frames := nil;
    InitRollData(Roll);
  end;
  if Doc <> nil then Doc.Free;
end;

procedure WriteRollHeader(Stream: TStream; const IDFPath: String; const Roll: TRollData;
  IsSLF: Boolean);
var
  GeneratedBy: String;
begin
  if IsSLF then
    GeneratedBy := 'Striplight SLF'
  else
    GeneratedBy := 'QuantumScan 1.02.26';
  StreamLine(Stream, '<?xml version="1.0" encoding="utf-8"?>');
  StreamLine(Stream, '<Roll RollName="' + XmlEscape(Roll.RollName) +
    '" RollNumber="' + XmlEscape(Roll.RollNumber) +
    '" JobName="' + XmlEscape(Roll.RollName) +
    '" RollID="' + XmlEscape(Roll.RollID) +
    '" GeneratedBy="' + GeneratedBy +
    '" ScanUserID="unknown" ProcessUserID="unknown">');
  if IsSLF then
    StreamLine(Stream, '  <StriplightSettings Format="SLF" Version="2" SourceIDFPath="' +
      XmlEscape(IDFPath) + '" SourceIDFFile="' + XmlEscape(ExtractFileName(IDFPath)) +
      '" SavedAt="' + XmlEscape(DateTimeToStr(Now)) +
      '" AdjustMethod="' + IntToStr(Roll.StriplightAdjustMethod) +
      '" AdjustFlags="' + IntToStr(Roll.StriplightAdjustFlags) +
      '" AdjustContrast="' + IntToStr(Roll.StriplightAdjustContrast) +
      '" AdjustBrightness="' + IntToStr(Roll.StriplightAdjustBrightness) +
      '" AdjustGamma="' + IntToStr(Roll.StriplightAdjustGamma) +
      '" Sharpness="' + IntToStr(Roll.StriplightSharpness) +
      '" SharpnessMode="' + IntToStr(Roll.StriplightSharpnessMode) +
      '" ExportNamingMode="' + IntToStr(Roll.StriplightExportNamingMode) +
      '" ExportGrayscale="' + BoolToStr(Roll.StriplightExportGrayscale, True) +
      '" ExportProgressive="' + BoolToStr(Roll.StriplightExportProgressive, True) +
      '" ExportEncoder="' + IntToStr(Roll.StriplightExportEncoder) +
      '" ArchiveList="' + XmlEscape(EncodeSLFText(Roll.StriplightArchiveList)) + '" />');
end;

procedure WriteScannerSettings(Stream: TStream; const Roll: TRollData; const IDValue: String;
  IncludeFrames: Boolean; const Frames: TFrameList; IncludeStriplightFields: Boolean);
var
  i: Integer;
  DetectionID: String;
begin
  if IncludeFrames and (not IncludeStriplightFields) then
    DetectionID := ''
  else
    DetectionID := IDValue;

  if IncludeFrames then
    StreamLine(Stream, '  <ScannerSettings ID="' + XmlEscape(IDValue) +
      '" StripCount="0" StartStripNumber="0" StartLineNumber="0" NegativeFilm="0" LensPosition="0" DPI="0" ReductionRatio="0" WidthPixels="0" LengthLines="0" StripImageFolder="" StripImageFilePrefix="" StripImageFileDigits="0" StripPreviewImageFolder="" StripPreviewImageFilePrefix="" StripPreviewImageFileDigits="0" StripPreviewDownScale="0" JpgQuality="0" SaveBitonalStrip="0" SaveGrayScaleStrip="0" SoftwareGrayAdjustEnable="0" SoftwareContrast="0" SoftwareBrightness="0" SoftwareGamma="0" StripLimitRegion="0" StripLeftOffset="0" StripPixels="0" IsFicheScan="0">')
  else
    StreamLine(Stream, '  <ScannerSettings ID="' + XmlEscape(IDValue) +
      '" StripCount="' + IntToStr(Roll.StripCount) +
      '" StartStripNumber="1" StartLineNumber="0" NegativeFilm="0" LensPosition="0" DPI="' + IntToStr(Roll.DPI) +
      '" ReductionRatio="0" WidthPixels="' + IntToStr(Roll.WidthPixels) +
      '" LengthLines="' + IntToStr(Roll.LengthLines) +
      '" StripImageFolder="' + XmlEscape(Roll.StripFolder) +
      '" StripImageFilePrefix="' + XmlEscape(Roll.StripPrefix) +
      '" StripImageFileDigits="' + IntToStr(Roll.StripDigits) +
      '" StripPreviewImageFolder="' + XmlEscape(Roll.PreviewSourceFolder) +
      '" StripPreviewImageFilePrefix="' + XmlEscape(Roll.PreviewPrefix) +
      '" StripPreviewImageFileDigits="' + IntToStr(Roll.StripDigits) +
      '" StripPreviewDownScale="' + IntToStr(Roll.PreviewDownScale) +
      '" JpgQuality="' + IntToStr(Roll.JpgQuality) +
      '" SaveBitonalStrip="0" SaveGrayScaleStrip="1" SoftwareGrayAdjustEnable="1" SoftwareContrast="' + IntToStr(Roll.SoftwareContrast) +
      '" SoftwareBrightness="' + IntToStr(Roll.SoftwareBrightness) +
      '" SoftwareGamma="' + IntToStr(Roll.SoftwareGamma) +
      '" StripLimitRegion="0" StripLeftOffset="0" StripPixels="' + IntToStr(Roll.StripPixels) +
      '" IsFicheScan="0">');

  StreamLine(Stream, '    <DetectionSettings ID="' + XmlEscape(DetectionID) +
    '" StartStripNumber="0" StartLineNumber="0" AutoFramingMode="1" DetectionThreshold="' + IntToStr(Roll.DetectionThreshold) +
    '" DetectMinWidth="' + IntToStr(Roll.DetectMinWidth) +
    '" DetectMinLength="' + IntToStr(Roll.DetectMinLength) +
    '" DetectOverscanWidth="100" DetectOverscanLines="100" DetectMinRunLength="12" DetectTouchRangeX="32" DetectTouchRangeY="3" DetectMaxFrameLength="32768" DetectLimitRegion="0" DetectLimitLeftOffset="0" DetectLimitPixels="' + IntToStr(Roll.StripPixels) +
    '" DetectInvertDetection="0" BlipDetection="0" BlipMinWidth="0" BlipMaxWidth="0" BlipMinLength="0" BlipMaxLength="0" BlipLimitRegion="0" BlipLimitLeftOffset="0" BlipLimitPixels="0" ProcessSettingsExist="1" ProcessSaveGrayscale="1" ProcessGrayscaleFormat="0" ProcessSaveBitonal="0" ProcessBitonalFormat="0" ProcessJpgQuality="' + IntToStr(Roll.JpgQuality) +
    '" ProcessSoftwareContrast="' + IntToStr(Roll.SoftwareContrast) +
    '" ProcessSoftwareBrightness="' + IntToStr(Roll.SoftwareBrightness) +
    '" ProcessSoftwareGamma="' + IntToStr(Roll.SoftwareGamma) +
    '" ProcessSoftwareGrayAdjust="1" ProcessBitonalThreshold="100" ProcessBitonalSensitivity="12" ProcessBitonalSlope="1" ProcessRotate="0" ProcessFlip="0" ProcessCrop="0" ProcessDeskew="0" ProcessInvert="0" ProcessCropThreshold="128" ProcessCropDetectPercent="20" ProcessCropDetectColor="255" ProcessCropBorderSize="0" ProcessDeskewFillColor="0" ProcessDeskewTransformQuality="0" ProcessCropFillBorder="0" ProcessCropFillColor="0" ProcessCropFillForward="0" ProcessGrayscaleOutputDirectory="" ProcessGrayscaleFilenamePrefix="gray" ProcessGrayscaleFilenameDigits="5" ProcessBitonalOutputDirectory="" ProcessBitonalFilenamePrefix="bitonal" ProcessBitonalFilenameDigits="5" ProcessDuplexNaming="0" ProcessDuplexNoSeparator="0" ProcessBlipNaming="0" ProcessBlipSizeMedium="1" ProcessBlipSizeLarge="1" ProcessFileStartNumber="1" ProcessBlipSaveSeparateFolders="0" ProcessBlipSepFolderTwoDeep="0" ProcessBlipNoMediumBlips="0" ProcessBlipSaveMultiPageFiles="0" ProcessMediumBlipRenumbering="0" ProcessMediumBlipStartNumber="1" ProcessLargeBlipStartNumber="1" ProcessAbsolutMaxFrameLength="32768" ProcessFicheSeparateFolders="0" ProcesscheckBoxFicheCompleteFile="0" ProcessFicheSeparateBy="0" ProcessFicheDualKeyEntry="0" ProcessFicheFindRowColOrder="0" ProcessFicheUseFicheNumbers="0" ProcessFicheSaveTitlescans="0" ProcessFicheSaveTitlescansForceGray="0" ProcessFicheSavePrescans="0" ProcessFicheStartLetter="A" ProcessFicheMultiPageFiles="0" ProcessFicheNamingStyle="0" ProcessMarkerSaveSeparateFolders="1" ProcessMarkerSaveMultiPageFiles="0" ProcessMarkerSaveMarkerFrames="1" ProcessReverseOrderNaming="0" ProcessMarkerUserSpecified="0" ProcessMarkerReuseMarkerNames="0" ProcessMarkerContinueCount="0" ProcessDuoNaming="0" ProcessSeparator="-" ProcessReverseUpperLower="0" ProcessReverseLeftRight="0" ProcessISIlog="0"' +
    IfThen(IncludeFrames, '>', ' />'));

  if IncludeFrames then
  begin
    for i := 0 to High(Frames) do
    begin
      if not IsPersistableFrame(Frames[i]) then
        Continue;
      StreamLine(Stream, '      <Frame LeadEdge="' + IntToStr(Frames[i].LeadEdge) +
        '" LeftEdge="' + IntToStr(Frames[i].LeftEdge) +
        '" RightEdge="' + IntToStr(Frames[i].RightEdge) +
        '" TrailEdge="' + IntToStr(Frames[i].TrailEdge) + '"' +
        IfThen(Frames[i].IsMarker, ' IsMarker="True"', '') +
        IfThen(Frames[i].PerFrameBrightness <> -1, ' PerFrameBrightness="' + IntToStr(Frames[i].PerFrameBrightness) + '"', '') +
        IfThen(Frames[i].PerFrameContrast <> -1, ' PerFrameContrast="' + IntToStr(Frames[i].PerFrameContrast) + '"', '') +
        IfThen(Frames[i].PerFrameGamma <> -1, ' PerFrameGamma="' + IntToStr(Frames[i].PerFrameGamma) + '"', '') +
        IfThen(Frames[i].Rotation <> 0, ' PerFrameRotate="' + IntToStr(Frames[i].Rotation) + '"', '') +
        IfThen(PerFrameFlipValue(Frames[i]) <> 0, ' PerFrameFlip="' + IntToStr(PerFrameFlipValue(Frames[i])) + '"', '') +
        IfThen(IncludeStriplightFields and Frames[i].IsSuggested, ' IsSuggested="True"', '') +
        IfThen(IncludeStriplightFields and (Frames[i].CustomBrightness <> -1), ' CustomBrightness="' + IntToStr(Frames[i].CustomBrightness) + '"', '') +
        IfThen(IncludeStriplightFields and (Frames[i].CustomContrast <> -1), ' CustomContrast="' + IntToStr(Frames[i].CustomContrast) + '"', '') +
        IfThen(IncludeStriplightFields and (Frames[i].CustomGamma <> -1), ' CustomGamma="' + IntToStr(Frames[i].CustomGamma) + '"', '') +
        IfThen(IncludeStriplightFields and (Frames[i].Rotation <> 0), ' Rotation="' + IntToStr(Frames[i].Rotation) + '"', '') +
        IfThen(IncludeStriplightFields and Frames[i].FlipH, ' FlipH="True"', '') +
        IfThen(IncludeStriplightFields and Frames[i].FlipV, ' FlipV="True"', '') +
        IfThen(IncludeStriplightFields and Frames[i].Negative, ' Negative="True"', '') +
        IfThen(IncludeStriplightFields and Frames[i].HasOverride, ' HasOverride="True"', '') +
        ' />');
    end;
    StreamLine(Stream, '    </DetectionSettings>');
  end;
  StreamLine(Stream, '  </ScannerSettings>');
end;

function SaveRollXML(const FileName, IDFPath: String; const Roll: TRollData;
  const Frames: TFrameList; IncludeStriplightFields: Boolean): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  Stream := nil;
  try
    ForceDirectories(ExtractFilePath(FileName));
    Stream := TFileStream.Create(FileName, fmCreate);
    WriteRollHeader(Stream, IDFPath, Roll, IncludeStriplightFields);
    WriteScannerSettings(Stream, Roll, '1', False, Frames, IncludeStriplightFields);
    WriteScannerSettings(Stream, Roll, 'QP', True, Frames, IncludeStriplightFields);
    StreamLine(Stream, '</Roll>');
    Result := True;
  except
    Result := False;
  end;
  if Stream <> nil then Stream.Free;
end;

function SaveQPF(const FileName, IDFPath: String; const Roll: TRollData;
                 const Frames: TFrameList): Boolean;
begin
  Result := SaveRollXML(FileName, IDFPath, Roll, Frames, False);
end;

function SaveSLF(const FileName, IDFPath: String; const Roll: TRollData;
                 const Frames: TFrameList): Boolean;
begin
  Result := SaveRollXML(FileName, IDFPath, Roll, Frames, True);
end;

function LoadIniFrames(const FileName: String; out Frames: TFrameList): Boolean;
var
  Ini: TIniFile;
  i, Total, Count: Integer;
  Sec: String;
  Frame: TFrameRecord;
begin
  Result := False;
  Frames := nil;
  try
    Ini := TIniFile.Create(FileName);
    try
      Total := Ini.ReadInteger('Roll', 'FrameCount', 0);
      if Total <= 0 then Exit;
      SetLength(Frames, 0);
      Count := 0;
      for i := 0 to Total - 1 do
      begin
        Sec := 'Frame_' + IntToStr(i);
        InitFrameRecord(Frame, Count);
        Frame.LeadEdge := StrToInt64Def(Ini.ReadString(Sec, 'LeadEdge', '0'), 0);
        Frame.TrailEdge := StrToInt64Def(Ini.ReadString(Sec, 'TrailEdge', '0'), 0);
        Frame.LeftEdge := Ini.ReadInteger(Sec, 'LeftEdge', 0);
        Frame.RightEdge := Ini.ReadInteger(Sec, 'RightEdge', 0);
        Frame.IsMarker := Ini.ReadBool(Sec, 'IsMarker', False);
        Frame.IsSuggested := Ini.ReadBool(Sec, 'IsSuggested', False);
        if not IsPersistableFrame(Frame) then
          Continue;
        SetLength(Frames, Count + 1);
        Frames[Count] := Frame;
        Frames[Count].Index := Count;
        Inc(Count);
      end;
      Result := Count > 0;
    finally
      Ini.Free;
    end;
  except
    Result := False;
    Frames := nil;
  end;
end;

function LoadQPF(const FileName: String; out Frames: TFrameList): Boolean;
begin
  Result := FileExists(FileName) and
            (LoadFramesFromRollXML(FileName, Frames) or LoadIniFrames(FileName, Frames));
end;

function LoadSLF(const FileName: String; out Frames: TFrameList): Boolean;
begin
  Result := LoadQPF(FileName, Frames);
end;

function LoadQPFProject(const FileName: String; out Roll: TRollData;
  out Frames: TFrameList): Boolean;
begin
  Result := FileExists(FileName) and LoadProjectFromRollXML(FileName, Roll, Frames);
end;

function LoadSLFProject(const FileName: String; out Roll: TRollData;
  out Frames: TFrameList): Boolean;
begin
  Result := FileExists(FileName) and LoadProjectFromRollXML(FileName, Roll, Frames);
  if Result then Exit;

  InitRollData(Roll);
  Roll.RollName := ChangeFileExt(ExtractFileName(FileName), '');
  Roll.BasePath := IncludeTrailingPathDelimiter(ExtractFilePath(FileName));
  Roll.PreviewBasePath := Roll.BasePath;
  Roll.PreviewSourceBasePath := Roll.BasePath;
  Roll.Loaded := LoadIniFrames(FileName, Frames);
  Result := Roll.Loaded;
end;

function SLFSourceIDFPath(const FileName: String): String;
var
  Ini: TIniFile;
begin
  Result := '';
  if not FileExists(FileName) then Exit;

  Result := SourceIDFFromRollXML(FileName);
  if Result <> '' then Exit;

  try
    Ini := TIniFile.Create(FileName);
    try
      if SameText(Ini.ReadString('Striplight', 'Format', ''), 'SLF') then
        Result := Ini.ReadString('Source', 'IDFPath', '');
    finally
      Ini.Free;
    end;
  except
    Result := '';
  end;
end;

end.


