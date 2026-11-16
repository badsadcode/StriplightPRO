unit uIDFParser;

{$mode objfpc}{$H+}

{ Parses the IDF (XML) files produced by QuantumScan.
  The document structure expected:

    <Roll RollName="..." RollNumber="..." RollID="...">
      <StartScan ... />
      <ScannerSettings StripCount="10960" DPI="300" WidthPixels="4916"
          LengthLines="4096" StripPreviewDownScale="16"
          StripImageFolder="strips"  StripPreviewImageFolder="previews"
          StripImageFilePrefix="strip"  StripImageFileDigits="9" ...>
        <DetectionSettings>
          <Frame LeadEdge="98476" TrailEdge="103108"
                 LeftEdge="3292"  RightEdge="4740" />
          ...
        </DetectionSettings>
      </ScannerSettings>
      <StopScan ... />
    </Roll>
}

interface

uses
  SysUtils, Classes, DOM, XMLRead, uTypes;
  { UTF8Encode / UTF8Decode are in the FPC System unit — no extra import needed }

type
  TIDFParseResult = (iprOK, iprFileNotFound, iprInvalidXML, iprMissingRoot,
                     iprMissingScanner);

function ParseIDF(const AFilename: String;
                  out ARoll:   TRollData;
                  out AFrames: TFrameList): TIDFParseResult;

function IDFResultMessage(R: TIDFParseResult): String;

implementation

{ ---------- Helper: safe attribute read ---------- }

{ DOMString = WideString in FPC's DOM unit.
  We convert explicitly to avoid implicit-cast warnings. }
function AttrStr(Node: TDOMNode; const Name: String;
                 const Default: String = ''): String;
var
  A: TDOMNode;
begin
  A := Node.Attributes.GetNamedItem(UTF8Decode(Name));
  if A = nil then Result := Default
  else Result := UTF8Encode(A.NodeValue);
end;

function AttrInt(Node: TDOMNode; const Name: String;
                 Default: Integer = 0): Integer;
begin
  Result := StrToIntDef(AttrStr(Node, Name), Default);
end;

{ ---------- Main parser ---------- }

function ParseIDF(const AFilename: String;
                  out ARoll:   TRollData;
                  out AFrames: TFrameList): TIDFParseResult;
var
  Doc           : TXMLDocument;
  RollNode      : TDOMNode;
  Child         : TDOMNode;
  ScannerNode   : TDOMNode;
  DetectionNode : TDOMNode;
  FrameNode     : TDOMNode;
  FrameCount    : Integer;
  i             : Integer;
  Frame         : TFrameRecord;
begin
  InitRollData(ARoll);
  SetLength(AFrames, 0);
  Result := iprOK;

  { --- File existence check --- }
  if not FileExists(AFilename) then
  begin
    Result := iprFileNotFound;
    Exit;
  end;

  { --- XML load --- }
  Doc := nil;
  try
    try
      ReadXMLFile(Doc, AFilename);
    except
      Result := iprInvalidXML;
      Exit;
    end;

    { --- Root element must be <Roll> --- }
    RollNode := Doc.DocumentElement;
    if (RollNode = nil) or (UTF8Encode(RollNode.NodeName) <> 'Roll') then
    begin
      Result := iprMissingRoot;
      Exit;
    end;

    { --- Roll attributes --- }
    ARoll.RollName   := AttrStr(RollNode, 'RollName');
    ARoll.RollNumber := AttrStr(RollNode, 'RollNumber');
    ARoll.RollID     := AttrStr(RollNode, 'RollID');
    ARoll.BasePath   := IncludeTrailingPathDelimiter(ExtractFilePath(AFilename));
    ARoll.PreviewBasePath := ARoll.BasePath;

    { Fall back to the IDF filename (no extension) if RollName is absent or placeholder }
    if (ARoll.RollName = '') or (LowerCase(ARoll.RollName) = 'none') then
      ARoll.RollName := ChangeFileExt(ExtractFileName(AFilename), '');

    { --- Find <ScannerSettings> --- }
    ScannerNode := nil;
    for i := 0 to Integer(RollNode.ChildNodes.Count) - 1 do
    begin
      Child := RollNode.ChildNodes.Item[i];
      if UTF8Encode(Child.NodeName) = 'ScannerSettings' then
      begin
        ScannerNode := Child;
        Break;
      end;
    end;

    if ScannerNode = nil then
    begin
      Result := iprMissingScanner;
      Exit;
    end;

    { --- Scanner settings --- }
    ARoll.StripCount       := AttrInt(ScannerNode, 'StripCount',            0);
    ARoll.DPI              := AttrInt(ScannerNode, 'DPI',                   300);
    ARoll.WidthPixels      := AttrInt(ScannerNode, 'WidthPixels',           4916);
    ARoll.LengthLines      := AttrInt(ScannerNode, 'LengthLines',           4096);
    ARoll.PreviewDownScale := AttrInt(ScannerNode, 'StripPreviewDownScale', DEFAULT_PREVIEW_DOWNSCALE);
    ARoll.StripFolder      := AttrStr(ScannerNode, 'StripImageFolder',      'strips');
    ARoll.PreviewFolder    := AttrStr(ScannerNode, 'StripPreviewImageFolder', 'previews');
    ARoll.PreviewSourceBasePath := ARoll.BasePath;
    ARoll.PreviewSourceFolder := ARoll.PreviewFolder;
    ARoll.StripPrefix      := AttrStr(ScannerNode, 'StripImageFilePrefix',         'strip');
    ARoll.PreviewPrefix    := AttrStr(ScannerNode, 'StripPreviewImageFilePrefix',  'preview');
    ARoll.StripDigits      := AttrInt(ScannerNode, 'StripImageFileDigits',  DEFAULT_STRIP_DIGITS);
    ARoll.StripPixels      := AttrInt(ScannerNode, 'StripPixels',           ARoll.WidthPixels);
    ARoll.JpgQuality       := AttrInt(ScannerNode, 'JpgQuality',            DEFAULT_JPG_QUALITY);
    ARoll.SoftwareContrast := AttrInt(ScannerNode, 'SoftwareContrast',      0);
    ARoll.SoftwareBrightness := AttrInt(ScannerNode, 'SoftwareBrightness',  0);
    ARoll.SoftwareGamma    := AttrInt(ScannerNode, 'SoftwareGamma',         0);

    { Guard against zero divides later }
    if ARoll.PreviewDownScale <= 0 then ARoll.PreviewDownScale := DEFAULT_PREVIEW_DOWNSCALE;
    if ARoll.LengthLines      <= 0 then ARoll.LengthLines      := 4096;
    if ARoll.WidthPixels      <= 0 then ARoll.WidthPixels      := 4916;

    { --- Find <DetectionSettings> inside ScannerSettings --- }
    DetectionNode := nil;
    for i := 0 to Integer(ScannerNode.ChildNodes.Count) - 1 do
    begin
      Child := ScannerNode.ChildNodes.Item[i];
      if UTF8Encode(Child.NodeName) = 'DetectionSettings' then
      begin
        DetectionNode := Child;
        Break;
      end;
    end;

    { Frames are optional (roll might not have been detected yet) }
    if DetectionNode = nil then
    begin
      ARoll.Loaded := True;
      Exit; // iprOK with 0 frames
    end;

    ARoll.DetectionThreshold := AttrInt(DetectionNode, 'DetectionThreshold', 100);
    ARoll.DetectMinWidth     := AttrInt(DetectionNode, 'DetectMinWidth',     252);
    ARoll.DetectMinLength    := AttrInt(DetectionNode, 'DetectMinLength',    252);

    { --- Parse <Frame> elements --- }
    // First pass: count
    FrameCount := 0;
    for i := 0 to Integer(DetectionNode.ChildNodes.Count) - 1 do
      if UTF8Encode(DetectionNode.ChildNodes.Item[i].NodeName) = 'Frame' then
        Inc(FrameCount);

    SetLength(AFrames, FrameCount);
    FrameCount := 0;

    for i := 0 to Integer(DetectionNode.ChildNodes.Count) - 1 do
    begin
      FrameNode := DetectionNode.ChildNodes.Item[i];
      if UTF8Encode(FrameNode.NodeName) <> 'Frame' then Continue;

      InitFrameRecord(Frame, FrameCount);
      Frame.LeadEdge  := StrToInt64Def(AttrStr(FrameNode, 'LeadEdge'),  0);
      Frame.TrailEdge := StrToInt64Def(AttrStr(FrameNode, 'TrailEdge'), 0);
      Frame.LeftEdge  := StrToIntDef  (AttrStr(FrameNode, 'LeftEdge'),  0);
      Frame.RightEdge := StrToIntDef  (AttrStr(FrameNode, 'RightEdge'), 0);

      AFrames[FrameCount] := Frame;
      Inc(FrameCount);
    end;

    ARoll.Loaded := True;
    Result       := iprOK;

  finally
    if Doc <> nil then Doc.Free;
  end;
end;

{ ---------- Result → human‑readable string ---------- }

function IDFResultMessage(R: TIDFParseResult): String;
begin
  case R of
    iprOK:             Result := 'OK';
    iprFileNotFound:   Result := 'IDF file not found.';
    iprInvalidXML:     Result := 'File is not valid XML.';
    iprMissingRoot:    Result := 'Expected <Roll> as root element.';
    iprMissingScanner: Result := '<ScannerSettings> element not found.';
  else
    Result := 'Unknown error.';
  end;
end;

end.
