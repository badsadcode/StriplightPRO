unit uStripView;

{$mode objfpc}{$H+}

{ TStripView – custom‑painted paged strip preview control.

  Layout logic:
    – Multiple strips are arranged in horizontal rows.
    – FStripsPerRow  controls how many appear side‑by‑side.
    – FRowsPerPage   is computed from the available height each time the
      control is resized.
    – A "page" is a fixed set of rows.  Navigation buttons advance/retract
      by one page.
    – Preview bitmaps are loaded lazily per‑page and freed on page change.

  Frame overlay colours (see uTypes):
    Green  – normal frame
    Red    – oversized or undersized
    Yellow – folder marker (drawn on top of green)
    Cyan   – selected
    Magenta dashed – auto‑suggested (IsSuggested, not yet confirmed)
}

interface

uses
  Classes, SysUtils, Controls, Graphics, LCLType, Menus,
  BGRABitmap, BGRABitmapTypes,
  Math, uTypes, uToneAdjust, uToneBitmap;

type
  { Drag/resize mode for frame handles }
  TDragMode = (dmNone, dmMove,
               dmResizeLead, dmResizeTrail,
               dmResizeLeft, dmResizeRight,
               dmResizeLeadLeft,  dmResizeLeadRight,
               dmResizeTrailLeft, dmResizeTrailRight,
               dmDrawNew,          { rubber-band to create a new frame }
               dmTrimTop,          { dragging the top trim line }
               dmTrimBottom,       { dragging the bottom trim line }
               dmDetectAreaTop,    { dragging detection ignored top edge }
               dmDetectAreaBottom, { dragging detection ignored bottom edge }
               dmDetectStart,      { dragging detection range start }
               dmDetectEnd);       { dragging detection range end }

  { Saved per-frame state for multi-frame drag }
  TMultiDragRec = record
    Idx   : Integer;
    Lead  : Int64;
    Trail : Int64;
    Left  : Integer;
    Right : Integer;
  end;
  TMultiDragArr = array of TMultiDragRec;

  { Simple integer array (used for hit cycling) }
  TIntArr = array of Integer;

  TBitmapCacheEntry = record
    StripIndex: Integer;
    Bitmap    : TBitmap;
    LastUsed  : Int64;
  end;
  TBitmapCache = array of TBitmapCacheEntry;

  TStripView = class(TCustomControl)
  private
    FRollData      : TRollData;
    FFrames        : TFrameList;
    FFrameStats    : TFrameStats;

    FStripsPerRow  : Integer;   // strips per row (user‑controlled)
    FRowsPerPage   : Integer;   // rows visible at once (auto‑computed on resize)
    FCurrentPage   : Integer;   // 0‑based current page index
    FZoom          : Double;    // 1.0 = base size

    FStripDisplayW : Integer;   // display width of one strip (pixels)
    FStripDisplayH : Integer;   // display height of one strip (pixels)
    FHGap          : Integer;   // horizontal gap between strips
    FVGap          : Integer;   // vertical gap between rows

    FFirstStrip    : Integer;   // index of first strip on current page
    FPageStripCount: Integer;   // number of strips visible on this page

    FBitmaps       : array of TBitmap;  // loaded bitmaps (nil = not loaded/missing)
    FBitmapCache   : TBitmapCache;      // processed strip bitmaps kept across pages
    FBitmapCacheClock: Int64;

    FRotateCW          : Boolean;    // True = CW 90°, False = CCW 90°
    FShowStripEdges    : Boolean;    // draw a marker line at each strip boundary
    FSelectionAnchor   : Integer;    // index of anchor frame for shift-click range select (-1 = none)
    FPreviewBrightness : Integer;
    FPreviewContrast   : Integer;
    FPreviewGamma      : Integer;
    FPreviewAdjustMode : Integer;
    FPreviewAdjustFlags: Integer;
    FPreviewStrength   : Integer;
    FPreviewNegative   : Boolean;
    FFrameFillOpacity  : Integer;
    FSplitPreviewEnabled: Boolean;
    FSplitPreviewParts : Integer;

    { Drag / resize state }
    FDragMode          : TDragMode;
    FDragFrameIdx      : Integer;    // index of frame being dragged (-1 = none)
    FDragStartX        : Integer;
    FDragStartY        : Integer;
    FDragStartLead     : Int64;
    FDragStartTrail    : Int64;
    FDragStartLeft     : Integer;
    FDragStartRight    : Integer;

    { Multi-frame manipulation }
    FMultiManipulate   : Boolean;     // when True, drag affects all selected frames
    FMultiDragArr      : TMultiDragArr;

    { Stacked-frame click cycling }
    FCycleX            : Integer;     // screen X of last cycle click
    FCycleY            : Integer;     // screen Y of last cycle click
    FCycleHits         : TIntArr;     // frame indices at cycle point (asc area order)
    FCycleIndex        : Integer;     // current position in cycle (-1 = inactive)

    { Draw-new frame (rubber-band) }
    FRubberX2          : Integer;     // current rubber-band end X (updated in MouseMove)
    FRubberY2          : Integer;     // current rubber-band end Y

    { Trim top / bottom }
    FTrimEnabled       : Boolean;
    FTrimTopPx         : Integer;     // full-res pixels to trim from LeftEdge side
    FTrimBottomPx      : Integer;     // full-res pixels to trim from RightEdge side
    FTrimDragStartPx   : Integer;     // trim value (top or bottom) at drag start

    FDetectRangeEnabled: Boolean;
    FDetectStartStrip  : Integer;     // 0-based, inclusive
    FDetectEndStrip    : Integer;     // 0-based, inclusive
    FDetectAreaTopPx   : Integer;     // full-res pixels ignored from LeftEdge side
    FDetectAreaBottomPx: Integer;     // full-res pixels ignored from RightEdge side
    FDetectAreaEnabled : Boolean;
    FDetectAreaDragStartPx: Integer;
    FContextStrip      : Integer;     // strip under last context-menu click
    FContextFrame      : Integer;     // frame under last context-menu click
    FPopupMenu         : TPopupMenu;

    FOnPageChanged     : TNotifyEvent;
    FOnSelectionChanged: TNotifyEvent;
    FOnFrameDblClick   : TNotifyEvent;
    FOnFrameChanged    : TNotifyEvent;  // fired after drag-resize/move or frame creation
    FOnExportMarkChanged: TNotifyEvent;
    FOnSelectFrameSection: TNotifyEvent;
    FOnDeleteFrameSection: TNotifyEvent;
    FOnTrimChanged     : TNotifyEvent;  // fired when trim values change via drag
    FOnDetectRangeChanged: TNotifyEvent;
    FOnDetectAreaChanged : TNotifyEvent;

    procedure OnPopupDetectStart(Sender: TObject);
    procedure OnPopupDetectEnd(Sender: TObject);
    procedure OnPopupPreviewFrame(Sender: TObject);
    procedure OnPopupSelectFrameSection(Sender: TObject);
    procedure OnPopupDeleteFrameSection(Sender: TObject);
    procedure OnPopupClearExportedFrame(Sender: TObject);
    procedure OnPopupClearSelectedExported(Sender: TObject);
    procedure OnPopupClearAllExported(Sender: TObject);

    procedure RecalcLayout;
    procedure LoadPageBitmaps;
    procedure FreePageBitmaps;
    procedure ClearBitmapCache;
    function  GetCachedBitmap(StripIdx: Integer): TBitmap;
    procedure AddBitmapToCache(StripIdx: Integer; ABitmap: TBitmap);
    procedure ApplyPreviewAdjustment(ABitmap: TBGRABitmap);

    procedure PaintBackground(ACanvas: TCanvas);
    procedure PaintStrips(ACanvas: TCanvas);
    procedure PaintFrameOverlays(ACanvas: TCanvas);
    procedure DrawSplitPreviewCuts(ACanvas: TCanvas; const F: TFrameRecord;
                                   ScaleX, ScaleY: Double);
    procedure DrawFrameRect(ACanvas: TCanvas; const R: TRect;
                            MainColor: TColor; IsMarker, IsSuggested: Boolean;
                            IsExported: Boolean = False;
                            HasPerFrameAdjustment: Boolean = False;
                            ShowHandles: Boolean = False;
                            IsLeadSeg: Boolean = True;
                            IsTrailSeg: Boolean = True);

    function StripRect(StripIdxOnPage: Integer): TRect;
    function HitTestStrip(X, Y: Integer): Integer;  // strip index on page, or -1
    function HitTestFrame(X, Y: Integer): Integer;  // frame index, or -1
    function SelectionAnchorCanExtend: Boolean;

    function GetTotalRows: Integer;
    function GetTotalPages: Integer;

    procedure SetStripsPerRow(Value: Integer);
    procedure SetZoom(Value: Double);
    procedure SetCurrentPage(Value: Integer);
    procedure SetRotateCW(Value: Boolean);
    procedure SetShowStripEdges(Value: Boolean);
    procedure SetFrameFillOpacity(Value: Integer);
    procedure SetSplitPreviewEnabled(Value: Boolean);
    procedure SetSplitPreviewParts(Value: Integer);
    procedure SetDetectRangeEnabled(Value: Boolean);
    procedure SetDetectStartStrip(Value: Integer);
    procedure SetDetectEndStrip(Value: Integer);
    procedure SetDetectAreaTopPx(Value: Integer);
    procedure SetDetectAreaBottomPx(Value: Integer);
    procedure SetDetectAreaEnabled(Value: Boolean);

    { Drag helpers }
    function  FrameHitHandle(FrameIdx, X, Y: Integer): TDragMode;
    function  HitHandleInRect(RX1, RY1, RX2, RY2, X, Y, HH: Integer;
                               IsLeadSeg, IsTrailSeg: Boolean): TDragMode;
    procedure ApplyDrag(X, Y: Integer);

    { Stacked-frame cycling helpers }
    procedure CollectHitsAtPoint(X, Y: Integer; out Hits: TIntArr);
    procedure ResetCycle;

    { Draw-new + trim helpers }
    function  ScreenToFilm(SX, SY: Integer; out FilmLead: Int64;
                            out FilmLeft: Integer): Boolean;
    function  TrimHitTest(Y: Integer): TDragMode;
    function  DetectAreaHitTest(Y: Integer): TDragMode;
    function  DetectRangeHitTest(X, Y: Integer): TDragMode;
    function  ScreenToDetectStrip(SX, SY: Integer; ForEndMarker: Boolean): Integer;
    procedure ShowContextMenuAt(X, Y: Integer);
    procedure PaintRubberBand(ACanvas: TCanvas);
    procedure PaintTrimOverlay(ACanvas: TCanvas);
    procedure PaintDetectionAreaOverlay(ACanvas: TCanvas);
    procedure PaintDetectRangeOverlay(ACanvas: TCanvas);

  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
                        X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
                      X, Y: Integer); override;
    procedure DblClick; override;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Load / clear }
    procedure LoadRoll(const ARoll: TRollData; const AFrames: TFrameList);
    procedure UpdateFrames(const AFrames: TFrameList);
    procedure ClearRoll;
    procedure TrimBitmapCacheToCurrentPage;
    procedure SetPreviewAdjustment(AContrast, ABrightness, AGamma: Integer; AMode: Integer = 0;
                                   AFlags: Integer = 0;
                                   AStrength: Integer = TONE_STRENGTH_DEFAULT;
                                   ANegative: Boolean = False);

    { Navigation }
    procedure GotoPage(PageIndex: Integer);
    procedure GotoFirst;
    procedure GotoLast;
    procedure GotoNext;
    procedure GotoPrev;

    { Selection helpers }
    procedure SelectAll;
    procedure SelectPage;
    procedure SelectNone;
    procedure SelectFrame(FrameIndex: Integer);
    procedure ToggleMarker(FrameIndex: Integer);
    procedure CancelInteraction;

    { Read‑only state }
    property CurrentPage  : Integer  read FCurrentPage;
    property TotalPages   : Integer  read GetTotalPages;
    property RowsPerPage  : Integer  read FRowsPerPage;
    property FirstStrip   : Integer  read FFirstStrip;
    property RollData     : TRollData  read FRollData;
    property Frames       : TFrameList read FFrames;

    { Configurable }
    property StripsPerRow : Integer  read FStripsPerRow write SetStripsPerRow;
    property Zoom         : Double   read FZoom         write SetZoom;
    property RotateCW      : Boolean  read FRotateCW      write SetRotateCW;
    property ShowStripEdges: Boolean  read FShowStripEdges write SetShowStripEdges;
    property FrameFillOpacity: Integer read FFrameFillOpacity write SetFrameFillOpacity;
    property SplitPreviewEnabled: Boolean read FSplitPreviewEnabled write SetSplitPreviewEnabled;
    property SplitPreviewParts: Integer read FSplitPreviewParts write SetSplitPreviewParts;
    property StripDisplayW : Integer  read FStripDisplayW;
    property DetectRangeEnabled: Boolean read FDetectRangeEnabled write SetDetectRangeEnabled;
    property DetectStartStrip: Integer read FDetectStartStrip write SetDetectStartStrip;
    property DetectEndStrip: Integer read FDetectEndStrip write SetDetectEndStrip;
    property DetectAreaTopPx: Integer read FDetectAreaTopPx write SetDetectAreaTopPx;
    property DetectAreaBottomPx: Integer read FDetectAreaBottomPx write SetDetectAreaBottomPx;
    property DetectAreaEnabled: Boolean read FDetectAreaEnabled write SetDetectAreaEnabled;
    property ContextFrame: Integer read FContextFrame;

    { Events }
    property MultiManipulate: Boolean read FMultiManipulate write FMultiManipulate;

    { Trim tool }
    property TrimEnabled  : Boolean read FTrimEnabled   write FTrimEnabled;
    property TrimTopPx    : Integer read FTrimTopPx     write FTrimTopPx;
    property TrimBottomPx : Integer read FTrimBottomPx  write FTrimBottomPx;

    { Events }
    property OnPageChanged     : TNotifyEvent read FOnPageChanged      write FOnPageChanged;
    property OnSelectionChanged: TNotifyEvent read FOnSelectionChanged write FOnSelectionChanged;
    property OnFrameDblClick   : TNotifyEvent read FOnFrameDblClick    write FOnFrameDblClick;
    property OnFrameChanged    : TNotifyEvent read FOnFrameChanged     write FOnFrameChanged;
    property OnExportMarkChanged: TNotifyEvent read FOnExportMarkChanged write FOnExportMarkChanged;
    property OnSelectFrameSection: TNotifyEvent read FOnSelectFrameSection write FOnSelectFrameSection;
    property OnDeleteFrameSection: TNotifyEvent read FOnDeleteFrameSection write FOnDeleteFrameSection;
    property OnTrimChanged     : TNotifyEvent read FOnTrimChanged      write FOnTrimChanged;
    property OnDetectRangeChanged: TNotifyEvent read FOnDetectRangeChanged write FOnDetectRangeChanged;
    property OnDetectAreaChanged : TNotifyEvent read FOnDetectAreaChanged write FOnDetectAreaChanged;
  end;

implementation

{ ---------- Constants ---------- }

const
  BASE_STRIP_W  = 160;   // display width at zoom 1.0 (pixels)
  MIN_ZOOM      = 0.25;
  MAX_ZOOM      = 4.0;
  MIN_STRIPS_PER_ROW = 1;
  MAX_STRIPS_PER_ROW = 20;
  H_GAP         = 0;   { 0 = edge-to-edge within a row }
  V_GAP         = 0;   { 0 = seamless: strip N bottom touches strip N+1 top }
  FRAME_PEN_W   = 2;
  HANDLE_HALF    = 5;   { half-size of drag handle squares in pixels }
  CYCLE_THRESH   = 12;  { max pixel distance to consider a re-click "same spot" for cycling }
  MAX_BITMAP_CACHE_ITEMS = 1000;
  ADJ_FLAG_SHADOW_LIFT = 1;
  ADJ_FLAG_HIGHLIGHT_RECOVERY = 2;
  ADJ_FLAG_S_CURVE = 4;
  ADJ_FLAG_DOCUMENT_RESCUE = 8;
  ADJ_FLAG_SOFT_CONTRAST = 16;

{ ============================================================ }
{ Construction / Destruction                                    }
{ ============================================================ }

constructor TStripView.Create(AOwner: TComponent);
var
  MI: TMenuItem;
begin
  inherited Create(AOwner);
  DoubleBuffered    := True;
  TabStop           := True;
  Color             := $202020;   // dark background
  FStripsPerRow     := 4;
  FZoom             := 1.0;
  FRotateCW         := False;
  FCurrentPage      := 0;
  FRowsPerPage      := 1;
  FHGap             := H_GAP;
  FVGap             := V_GAP;
  FStripDisplayW    := Round(BASE_STRIP_W * FZoom);
  FStripDisplayH    := FStripDisplayW;   // adjusted once roll loaded
  FSelectionAnchor  := -1;
  FPreviewBrightness := 0;
  FPreviewContrast   := 0;
  FPreviewGamma      := 100;
  FPreviewAdjustMode := 0;
  FPreviewAdjustFlags := 0;
  FPreviewStrength := TONE_STRENGTH_DEFAULT;
  FPreviewNegative := False;
  FFrameFillOpacity  := 35;
  FSplitPreviewEnabled := False;
  FSplitPreviewParts := 2;
  FDragMode         := dmNone;
  FDragFrameIdx     := -1;
  FMultiManipulate  := False;
  FCycleIndex       := -1;
  FCycleX           := -1;
  FCycleY           := -1;
  FRubberX2         := 0;
  FRubberY2         := 0;
  FTrimEnabled      := False;
  FTrimTopPx        := 100;
  FTrimBottomPx     := 100;
  FTrimDragStartPx  := 0;
  FDetectRangeEnabled := False;
  FDetectStartStrip   := 0;
  FDetectEndStrip     := 0;
  FDetectAreaTopPx    := 0;
  FDetectAreaBottomPx := 0;
  FDetectAreaEnabled  := False;
  FDetectAreaDragStartPx := 0;
  FContextStrip        := -1;
  FContextFrame        := -1;
  FPopupMenu := TPopupMenu.Create(Self);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Preview Frame';
  MI.OnClick := @OnPopupPreviewFrame;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Select Frame Section';
  MI.OnClick := @OnPopupSelectFrameSection;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Delete Frame Section from Marker';
  MI.OnClick := @OnPopupDeleteFrameSection;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := '-';
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Clear Processed Mark';
  MI.OnClick := @OnPopupClearExportedFrame;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Clear Selected Processed Marks';
  MI.OnClick := @OnPopupClearSelectedExported;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Clear All Processed Marks';
  MI.OnClick := @OnPopupClearAllExported;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := '-';
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Set Detection Start Here';
  MI.OnClick := @OnPopupDetectStart;
  FPopupMenu.Items.Add(MI);
  MI := TMenuItem.Create(FPopupMenu);
  MI.Caption := 'Set Detection End Here';
  MI.OnClick := @OnPopupDetectEnd;
  FPopupMenu.Items.Add(MI);
  InitRollData(FRollData);
end;

destructor TStripView.Destroy;
begin
  FreePageBitmaps;
  ClearBitmapCache;
  inherited Destroy;
end;

{ ============================================================ }
{ Layout helpers                                                }
{ ============================================================ }

procedure TStripView.RecalcLayout;
var
  PreviewH, PreviewW: Integer;
  RowH, AvailH: Integer;
begin
  { Display size of each strip }
  FStripDisplayW := Round(BASE_STRIP_W * FZoom);

  if FRollData.Loaded and (FRollData.WidthPixels > 0) and (FRollData.LengthLines > 0) then
  begin
    PreviewW := Max(1, FRollData.WidthPixels  div FRollData.PreviewDownScale);
    PreviewH := Max(1, FRollData.LengthLines  div FRollData.PreviewDownScale);
    { After 90° rotation original W becomes displayed H and vice versa }
    FStripDisplayH := Round(FStripDisplayW * PreviewW / PreviewH);
  end
  else
    FStripDisplayH := FStripDisplayW;  // square placeholder

  { How many rows fit in the control height? }
  RowH  := FStripDisplayH + FVGap;
  AvailH := Max(1, ClientHeight);
  FRowsPerPage := Max(1, AvailH div RowH);
end;

function TStripView.StripRect(StripIdxOnPage: Integer): TRect;
var
  Row, Col: Integer;
begin
  Row := StripIdxOnPage div FStripsPerRow;
  Col := StripIdxOnPage mod FStripsPerRow;
  Result.Left   := FHGap + Col * (FStripDisplayW + FHGap);
  Result.Top    := FVGap + Row * (FStripDisplayH + FVGap);
  Result.Right  := Result.Left + FStripDisplayW;
  Result.Bottom := Result.Top  + FStripDisplayH;
end;

function TStripView.GetTotalRows: Integer;
begin
  if not FRollData.Loaded then Result := 0
  else Result := (FRollData.StripCount + FStripsPerRow - 1) div FStripsPerRow;
end;

function TStripView.GetTotalPages: Integer;
var
  TR: Integer;
begin
  TR := GetTotalRows;
  if TR = 0 then Result := 0
  else Result := (TR + FRowsPerPage - 1) div FRowsPerPage;
end;

{ ============================================================ }
{ Bitmap management                                             }
{ ============================================================ }

procedure TStripView.LoadPageBitmaps;
var
  i, StripIdx: Integer;
  Path: String;
  CachedBmp, PageBmp: TBitmap;
  Bgra, Rotated: TBGRABitmap;
begin
  FreePageBitmaps;

  if not FRollData.Loaded then Exit;

  { Determine how many strips appear on this page }
  FFirstStrip := FCurrentPage * (FStripsPerRow * FRowsPerPage);
  FPageStripCount := Min(FStripsPerRow * FRowsPerPage,
                         FRollData.StripCount - FFirstStrip);
  if FPageStripCount < 0 then FPageStripCount := 0;

  SetLength(FBitmaps, FPageStripCount);
  for i := 0 to FPageStripCount - 1 do
    FBitmaps[i] := nil;

  for i := 0 to FPageStripCount - 1 do
  begin
    StripIdx := FFirstStrip + i;
    CachedBmp := GetCachedBitmap(StripIdx);
    if CachedBmp <> nil then
    begin
      FBitmaps[i] := CachedBmp;
      Continue;
    end;

    Path := PreviewFilePath(FRollData, StripIdx);
    if not FileExists(Path) then Continue;

    Bgra    := nil;
    Rotated := nil;
    PageBmp := nil;
    try
      try
        Bgra := TBGRABitmap.Create(Path);
        ApplyPreviewAdjustment(Bgra);
        if FRotateCW then
          Rotated := Bgra.RotateCW
        else
          Rotated := Bgra.RotateCCW;
        { A clockwise source correction needs this flip to keep film order
          left-to-right.  The default scanner orientation is corrected with
          CCW rotation only; flipping that path mirrors the image. }
        if FRotateCW then
          Rotated.HorizontalFlip;
        PageBmp := Rotated.MakeBitmapCopy(clBlack);
        AddBitmapToCache(StripIdx, PageBmp);
        FBitmaps[i] := PageBmp;
        PageBmp := nil;
      except
        FreeAndNil(PageBmp);
        FBitmaps[i] := nil;
      end;
    finally
      Rotated.Free;
      Bgra.Free;
    end;
  end;
end;

procedure TStripView.FreePageBitmaps;
begin
  { FBitmaps only references entries owned by FBitmapCache. }
  SetLength(FBitmaps, 0);
  FPageStripCount := 0;
end;

procedure TStripView.ClearBitmapCache;
var
  i: Integer;
begin
  SetLength(FBitmaps, 0);
  for i := 0 to High(FBitmapCache) do
    FBitmapCache[i].Bitmap.Free;
  SetLength(FBitmapCache, 0);
  FBitmapCacheClock := 0;
end;

procedure TStripView.TrimBitmapCacheToCurrentPage;
var
  i, KeepCount, FirstKeep, LastKeep: Integer;
  NewCache: TBitmapCache;
begin
  if Length(FBitmapCache) = 0 then Exit;

  FirstKeep := FFirstStrip;
  LastKeep := FFirstStrip + FPageStripCount - 1;
  KeepCount := 0;
  SetLength(NewCache, Length(FBitmapCache));
  for i := 0 to High(FBitmapCache) do
  begin
    if (FBitmapCache[i].StripIndex >= FirstKeep) and
       (FBitmapCache[i].StripIndex <= LastKeep) then
    begin
      NewCache[KeepCount] := FBitmapCache[i];
      Inc(KeepCount);
    end
    else
      FBitmapCache[i].Bitmap.Free;
  end;

  SetLength(NewCache, KeepCount);
  FBitmapCache := NewCache;
  SetLength(FBitmaps, FPageStripCount);
  for i := 0 to FPageStripCount - 1 do
    FBitmaps[i] := GetCachedBitmap(FFirstStrip + i);
end;

function TStripView.GetCachedBitmap(StripIdx: Integer): TBitmap;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to High(FBitmapCache) do
    if FBitmapCache[i].StripIndex = StripIdx then
    begin
      Inc(FBitmapCacheClock);
      FBitmapCache[i].LastUsed := FBitmapCacheClock;
      Result := FBitmapCache[i].Bitmap;
      Exit;
    end;
end;

procedure TStripView.AddBitmapToCache(StripIdx: Integer; ABitmap: TBitmap);
var
  i, Slot, OldestIdx: Integer;
  OldestUsed: Int64;
begin
  if ABitmap = nil then Exit;

  for i := 0 to High(FBitmapCache) do
    if FBitmapCache[i].StripIndex = StripIdx then
    begin
      FBitmapCache[i].Bitmap.Free;
      Inc(FBitmapCacheClock);
      FBitmapCache[i].Bitmap := ABitmap;
      FBitmapCache[i].LastUsed := FBitmapCacheClock;
      Exit;
    end;

  if Length(FBitmapCache) < MAX_BITMAP_CACHE_ITEMS then
  begin
    Slot := Length(FBitmapCache);
    SetLength(FBitmapCache, Slot + 1);
  end
  else
  begin
    OldestIdx := 0;
    OldestUsed := FBitmapCache[0].LastUsed;
    for i := 1 to High(FBitmapCache) do
      if FBitmapCache[i].LastUsed < OldestUsed then
      begin
        OldestIdx := i;
        OldestUsed := FBitmapCache[i].LastUsed;
      end;
    Slot := OldestIdx;
    FBitmapCache[Slot].Bitmap.Free;
  end;

  Inc(FBitmapCacheClock);
  FBitmapCache[Slot].StripIndex := StripIdx;
  FBitmapCache[Slot].Bitmap := ABitmap;
  FBitmapCache[Slot].LastUsed := FBitmapCacheClock;
end;

procedure TStripView.ApplyPreviewAdjustment(ABitmap: TBGRABitmap);
begin
  if (ABitmap = nil) or
     (((FPreviewAdjustMode = 0) and (FPreviewBrightness = 0) and
       (FPreviewContrast = 0) and (FPreviewGamma = 100) and
       (FPreviewAdjustFlags = 0)) or
      ((FPreviewAdjustMode = 1) and (FPreviewBrightness = 0) and
       (FPreviewContrast = 64) and (FPreviewGamma = 0) and
       (FPreviewAdjustFlags = 0))) then Exit;

  { The adaptive methods are applied to each strip preview here, while the
    export applies them to each frame. The strip view is therefore a close
    guide for those methods; the frame preview window shows the exact result. }
  ApplyToneToBitmap(ABitmap, FPreviewAdjustMode, FPreviewAdjustFlags,
    FPreviewContrast, FPreviewBrightness, FPreviewGamma, FPreviewStrength,
    FPreviewNegative);
end;

{ ============================================================ }
{ Hit testing                                                   }
{ ============================================================ }

function TStripView.HitTestStrip(X, Y: Integer): Integer;
var
  i: Integer;
  R: TRect;
begin
  Result := -1;
  for i := 0 to FPageStripCount - 1 do
  begin
    R := StripRect(i);
    if PtInRect(Point(X, Y), R) then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

function TStripView.HitTestFrame(X, Y: Integer): Integer;
{ Returns the index of the topmost (smallest) frame under the cursor. }
var
  i: Integer;
  F: TFrameRecord;
  S1, S2, S: Integer;
  StripR: TRect;
  PreviewH, PreviewW: Integer;
  ScaleX, ScaleY: Double;
  LocalLeadY, LocalTrailY, LocalLeft, LocalRight: Integer;
  FX1, FX2, FY1, FY2: Integer;
  BestArea: Int64;
  Area: Int64;
begin
  Result := -1;
  if not FRollData.Loaded then Exit;

  PreviewW := Max(1, FRollData.WidthPixels div FRollData.PreviewDownScale);
  PreviewH := Max(1, FRollData.LengthLines div FRollData.PreviewDownScale);
  { CW+HFlip = transpose — same scale as PaintFrameOverlays }
  ScaleX := FStripDisplayW / PreviewH;
  ScaleY := FStripDisplayH / PreviewW;

  BestArea := MaxInt;

  for i := 0 to High(FFrames) do
  begin
    F  := FFrames[i];
    S1 := FrameLeadStrip(F, FRollData.LengthLines);
    S2 := FrameTrailStrip(F, FRollData.LengthLines);
    if (S2 < FFirstStrip) or (S1 > FFirstStrip + FPageStripCount - 1) then Continue;

    for S := Max(S1, FFirstStrip) to Min(S2, FFirstStrip + FPageStripCount - 1) do
    begin
      StripR := StripRect(S - FFirstStrip);

      LocalLeft  := Round(F.LeftEdge  / FRollData.PreviewDownScale);
      LocalRight := Round(F.RightEdge / FRollData.PreviewDownScale);

      if S = S1 then
        LocalLeadY := Integer(F.LeadEdge  mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalLeadY := 0;

      if S = S2 then
        LocalTrailY := Integer(F.TrailEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalTrailY := PreviewH;

      { CW+HFlip = transpose — mirrors PaintFrameOverlays }
      FX1 := StripR.Left + Round(LocalLeadY  * ScaleX);
      FX2 := StripR.Left + Round(LocalTrailY * ScaleX);
      FY1 := StripR.Top  + Round(LocalLeft   * ScaleY);
      FY2 := StripR.Top  + Round(LocalRight  * ScaleY);

      if (X >= FX1) and (X <= FX2) and (Y >= FY1) and (Y <= FY2) then
      begin
        Area := Int64(FX2 - FX1) * Int64(FY2 - FY1);
        if Area < BestArea then
        begin
          BestArea := Area;
          Result := i;
        end;
      end;
    end;
  end;
end;

function TStripView.SelectionAnchorCanExtend: Boolean;
begin
  Result := (FSelectionAnchor >= 0) and
            (FSelectionAnchor <= High(FFrames)) and
            FFrames[FSelectionAnchor].IsSelected;
end;

{ ============================================================ }
{ Painting                                                      }
{ ============================================================ }

{ ============================================================ }
{ Draw-new + trim helpers                                       }
{ ============================================================ }

function TStripView.ScreenToFilm(SX, SY: Integer;
                                  out FilmLead: Int64;
                                  out FilmLeft: Integer): Boolean;
{ Converts a screen point to full-res film coordinates.
  Returns False if the point is not inside any visible strip. }
var
  sp: Integer;
  SR: TRect;
  PreviewH, PreviewW: Integer;
  ScaleX, ScaleY: Double;
begin
  Result := False;
  if not FRollData.Loaded then Exit;
  sp := HitTestStrip(SX, SY);
  if sp < 0 then Exit;

  SR       := StripRect(sp);
  PreviewW := Max(1, FRollData.WidthPixels div FRollData.PreviewDownScale);
  PreviewH := Max(1, FRollData.LengthLines div FRollData.PreviewDownScale);
  ScaleX   := FStripDisplayW / PreviewH;
  ScaleY   := FStripDisplayH / PreviewW;

  { CW+HFlip transpose: screen X → film Y (lead/trail), screen Y → film X (left/right) }
  FilmLead := Int64(FFirstStrip + sp) * FRollData.LengthLines
            + Round((SX - SR.Left) / ScaleX) * FRollData.PreviewDownScale;
  FilmLeft := Round((SY - SR.Top) / ScaleY) * FRollData.PreviewDownScale;

  { Clamp to strip bounds }
  FilmLead := Max(Int64(FFirstStrip + sp) * FRollData.LengthLines,
              Min(Int64(FFirstStrip + sp + 1) * FRollData.LengthLines - 1, FilmLead));
  FilmLeft := Max(0, Min(FRollData.WidthPixels, FilmLeft));
  Result := True;
end;

function TStripView.TrimHitTest(Y: Integer): TDragMode;
{ Returns dmTrimTop or dmTrimBottom if Y is within HANDLE_HALF of any trim line
  on the current page.  Sets FTrimDragStartPx to the current trim value for
  delta computation during drag. }
var
  row, rowCount: Integer;
  rowTopY, rowBottomY: Integer;
  trimTopY, trimBotY: Integer;
  scaleY: Double;
begin
  Result := dmNone;
  if not FTrimEnabled or not FRollData.Loaded or (FRollData.WidthPixels = 0) then Exit;

  scaleY   := FStripDisplayH / FRollData.WidthPixels;   { screen px per full-res px }
  rowCount := (FPageStripCount + FStripsPerRow - 1) div FStripsPerRow;

  for row := 0 to rowCount - 1 do
  begin
    rowTopY    := FVGap + row * (FStripDisplayH + FVGap);
    rowBottomY := rowTopY + FStripDisplayH;

    if FTrimTopPx > 0 then
    begin
      trimTopY := rowTopY + Round(FTrimTopPx * scaleY);
      if Abs(Y - trimTopY) <= HANDLE_HALF then
      begin
        FTrimDragStartPx := FTrimTopPx;
        Exit(dmTrimTop);
      end;
    end;

    if FTrimBottomPx > 0 then
    begin
      trimBotY := rowBottomY - Round(FTrimBottomPx * scaleY);
      if Abs(Y - trimBotY) <= HANDLE_HALF then
      begin
        FTrimDragStartPx := FTrimBottomPx;
        Exit(dmTrimBottom);
      end;
    end;
  end;
end;

function TStripView.DetectAreaHitTest(Y: Integer): TDragMode;
var
  row, rowCount: Integer;
  rowTopY, rowBottomY: Integer;
  topY, bottomY: Integer;
  scaleY: Double;
begin
  Result := dmNone;
  if not FDetectAreaEnabled or not FRollData.Loaded or (FRollData.WidthPixels = 0) then Exit;

  scaleY   := FStripDisplayH / FRollData.WidthPixels;
  rowCount := (FPageStripCount + FStripsPerRow - 1) div FStripsPerRow;

  for row := 0 to rowCount - 1 do
  begin
    rowTopY    := FVGap + row * (FStripDisplayH + FVGap);
    rowBottomY := rowTopY + FStripDisplayH;

    topY := rowTopY + Round(FDetectAreaTopPx * scaleY);
    if Abs(Y - topY) <= HANDLE_HALF then
    begin
      FDetectAreaDragStartPx := FDetectAreaTopPx;
      Exit(dmDetectAreaTop);
    end;

    bottomY := rowBottomY - Round(FDetectAreaBottomPx * scaleY);
    if Abs(Y - bottomY) <= HANDLE_HALF then
    begin
      FDetectAreaDragStartPx := FDetectAreaBottomPx;
      Exit(dmDetectAreaBottom);
    end;
  end;
end;

function TStripView.DetectRangeHitTest(X, Y: Integer): TDragMode;
var
  R: TRect;
  StartOnPage, EndOnPage: Integer;
  StartX, EndX: Integer;
begin
  Result := dmNone;
  if not FDetectRangeEnabled or not FRollData.Loaded then Exit;

  StartOnPage := FDetectStartStrip - FFirstStrip;
  if (StartOnPage >= 0) and (StartOnPage < FPageStripCount) then
  begin
    R := StripRect(StartOnPage);
    StartX := R.Left;
    if (Y >= R.Top) and (Y <= R.Bottom) and (Abs(X - StartX) <= HANDLE_HALF + 2) then
      Exit(dmDetectStart);
  end;

  EndOnPage := FDetectEndStrip - FFirstStrip;
  if (EndOnPage >= 0) and (EndOnPage < FPageStripCount) then
  begin
    R := StripRect(EndOnPage);
    EndX := R.Right - 1;
    if (Y >= R.Top) and (Y <= R.Bottom) and (Abs(X - EndX) <= HANDLE_HALF + 2) then
      Exit(dmDetectEnd);
  end;
end;

function TStripView.ScreenToDetectStrip(SX, SY: Integer; ForEndMarker: Boolean): Integer;
var
  sp: Integer;
begin
  Result := -1;
  if not FRollData.Loaded then Exit;
  sp := HitTestStrip(SX, SY);
  if sp < 0 then Exit;
  Result := FFirstStrip + sp;
  if Result < 0 then Result := 0;
  if Result > FRollData.StripCount - 1 then Result := FRollData.StripCount - 1;
end;

procedure TStripView.ShowContextMenuAt(X, Y: Integer);
var
  sp, i: Integer;
  HasSelectedExported, HasAnyExported: Boolean;
  P: TPoint;
begin
  FContextStrip := -1;
  FContextFrame := -1;
  if not FRollData.Loaded then Exit;
  sp := HitTestStrip(X, Y);
  if sp < 0 then Exit;
  FContextStrip := FFirstStrip + sp;
  FContextFrame := HitTestFrame(X, Y);
  FPopupMenu.Items[0].Enabled := FContextFrame >= 0;
  FPopupMenu.Items[1].Enabled := FContextFrame >= 0;
  FPopupMenu.Items[2].Enabled := FContextFrame >= 0;
  FPopupMenu.Items[4].Enabled := (FContextFrame >= 0) and FFrames[FContextFrame].IsExported;
  HasSelectedExported := False;
  HasAnyExported := False;
  for i := 0 to High(FFrames) do
  begin
    if FFrames[i].IsExported then
      HasAnyExported := True;
    if FFrames[i].IsSelected and FFrames[i].IsExported then
    begin
      HasSelectedExported := True;
    end;
  end;
  FPopupMenu.Items[5].Enabled := HasSelectedExported;
  FPopupMenu.Items[6].Enabled := HasAnyExported;
  P := ClientToScreen(Point(X, Y));
  FPopupMenu.PopUp(P.X, P.Y);
end;

procedure TStripView.OnPopupPreviewFrame(Sender: TObject);
var
  i: Integer;
begin
  if FContextFrame < 0 then Exit;
  for i := 0 to High(FFrames) do
    FFrames[i].IsSelected := (i = FContextFrame);
  FSelectionAnchor := FContextFrame;
  CancelInteraction;
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
  if Assigned(FOnFrameDblClick) then FOnFrameDblClick(Self);
end;

procedure TStripView.OnPopupDeleteFrameSection(Sender: TObject);
begin
  if FContextFrame < 0 then Exit;
  if Assigned(FOnDeleteFrameSection) then FOnDeleteFrameSection(Self);
end;

procedure TStripView.OnPopupSelectFrameSection(Sender: TObject);
begin
  if FContextFrame < 0 then Exit;
  if Assigned(FOnSelectFrameSection) then FOnSelectFrameSection(Self);
end;

procedure TStripView.OnPopupClearExportedFrame(Sender: TObject);
begin
  if (FContextFrame < 0) or (FContextFrame > High(FFrames)) then Exit;
  FFrames[FContextFrame].IsExported := False;
  Invalidate;
  if Assigned(FOnExportMarkChanged) then FOnExportMarkChanged(Self);
end;

procedure TStripView.OnPopupClearSelectedExported(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      FFrames[i].IsExported := False;
  Invalidate;
  if Assigned(FOnExportMarkChanged) then FOnExportMarkChanged(Self);
end;

procedure TStripView.OnPopupClearAllExported(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FFrames) do
    FFrames[i].IsExported := False;
  Invalidate;
  if Assigned(FOnExportMarkChanged) then FOnExportMarkChanged(Self);
end;

procedure TStripView.OnPopupDetectStart(Sender: TObject);
begin
  if FContextStrip < 0 then Exit;
  FDetectRangeEnabled := True;
  FDetectStartStrip := FContextStrip;
  if FDetectEndStrip < FDetectStartStrip then FDetectEndStrip := FDetectStartStrip;
  Invalidate;
  if Assigned(FOnDetectRangeChanged) then FOnDetectRangeChanged(Self);
end;

procedure TStripView.OnPopupDetectEnd(Sender: TObject);
begin
  if FContextStrip < 0 then Exit;
  FDetectRangeEnabled := True;
  FDetectEndStrip := FContextStrip;
  if FDetectStartStrip > FDetectEndStrip then FDetectStartStrip := FDetectEndStrip;
  Invalidate;
  if Assigned(FOnDetectRangeChanged) then FOnDetectRangeChanged(Self);
end;

procedure TStripView.PaintDetectRangeOverlay(ACanvas: TCanvas);
var
  R: TRect;
  StartOnPage, EndOnPage: Integer;

  procedure DrawMarker(X: Integer; const Caption: String; Color: TColor);
  begin
    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Width := 3;
    ACanvas.Pen.Color := Color;
    ACanvas.MoveTo(X, R.Top);
    ACanvas.LineTo(X, R.Bottom);
    ACanvas.Brush.Style := bsSolid;
    ACanvas.Brush.Color := Color;
    ACanvas.Font.Color := clBlack;
    ACanvas.Font.Size := 8;
    ACanvas.TextOut(X + 4, R.Top + 4, Caption);
    ACanvas.Brush.Style := bsClear;
  end;

begin
  if not FDetectRangeEnabled or not FRollData.Loaded then Exit;

  StartOnPage := FDetectStartStrip - FFirstStrip;
  if (StartOnPage >= 0) and (StartOnPage < FPageStripCount) then
  begin
    R := StripRect(StartOnPage);
    DrawMarker(R.Left, 'Detect From', COL_FRAME_SELECTED);
  end;

  EndOnPage := FDetectEndStrip - FFirstStrip;
  if (EndOnPage >= 0) and (EndOnPage < FPageStripCount) then
  begin
    R := StripRect(EndOnPage);
    DrawMarker(R.Right - 1, 'Detect To', $000080FF);
  end;

  ACanvas.Pen.Style := psSolid;
  ACanvas.Pen.Width := 1;
  ACanvas.Brush.Style := bsClear;
end;

procedure TStripView.PaintTrimOverlay(ACanvas: TCanvas);
{ Draws semi-transparent yellow bands + bright lines at the trim positions
  within every displayed strip row.  Uses BGRABitmap alpha-blend so the
  overlay is translucent rather than an opaque hatch pattern. }
var
  row, rowCount: Integer;
  rowTopY, rowBottomY: Integer;
  trimTopY, trimBotY: Integer;
  scaleY: Double;
  bandH: Integer;
  Overlay: TBGRABitmap;

  { Draw one semi-transparent yellow rectangle via BGRABitmap alpha-blend }
  procedure DrawBand(X, Y, W, H: Integer);
  begin
    if (W <= 0) or (H <= 0) then Exit;
    Overlay := TBGRABitmap.Create(W, H);
    try
      Overlay.Fill(BGRA(255, 200, 0, 140));  { golden-yellow, ~55% opacity }
      Overlay.Draw(ACanvas, X, Y, False);    { False = use alpha channel }
    finally
      Overlay.Free;
    end;
  end;

begin
  if not FTrimEnabled or not FRollData.Loaded or (FRollData.WidthPixels = 0) then Exit;

  scaleY   := FStripDisplayH / FRollData.WidthPixels;
  rowCount := (FPageStripCount + FStripsPerRow - 1) div FStripsPerRow;

  for row := 0 to rowCount - 1 do
  begin
    rowTopY    := FVGap + row * (FStripDisplayH + FVGap);
    rowBottomY := rowTopY + FStripDisplayH;

    trimTopY := rowTopY;
    trimBotY := rowBottomY;

    { Top trim band — semi-transparent yellow }
    if FTrimTopPx > 0 then
    begin
      trimTopY := rowTopY + Round(FTrimTopPx * scaleY);
      bandH    := trimTopY - rowTopY;
      DrawBand(0, rowTopY, ClientWidth, bandH);
    end;

    { Bottom trim band — semi-transparent yellow }
    if FTrimBottomPx > 0 then
    begin
      trimBotY := rowBottomY - Round(FTrimBottomPx * scaleY);
      bandH    := rowBottomY - trimBotY;
      DrawBand(0, trimBotY, ClientWidth, bandH);
    end;

    { Trim lines: bright yellow, 2px, draggable }
    ACanvas.Pen.Style   := psSolid;
    ACanvas.Pen.Width   := 2;
    ACanvas.Pen.Color   := clYellow;
    ACanvas.Brush.Style := bsClear;

    if FTrimTopPx > 0 then
    begin
      ACanvas.MoveTo(0, trimTopY);
      ACanvas.LineTo(ClientWidth, trimTopY);
    end;
    if FTrimBottomPx > 0 then
    begin
      ACanvas.MoveTo(0, trimBotY);
      ACanvas.LineTo(ClientWidth, trimBotY);
    end;
  end;

  { Restore canvas state for subsequent draw calls (frame overlays etc.) }
  ACanvas.Pen.Style   := psSolid;
  ACanvas.Pen.Width   := 1;
  ACanvas.Brush.Style := bsClear;
end;

procedure TStripView.PaintDetectionAreaOverlay(ACanvas: TCanvas);
{ Draws live blue ignored-edge bands used by the detection-area controls. }
var
  row, rowCount: Integer;
  rowTopY, rowBottomY: Integer;
  ignoreTopY, ignoreBotY: Integer;
  scaleY: Double;
  bandH: Integer;
  Overlay: TBGRABitmap;

  procedure DrawBand(X, Y, W, H: Integer);
  begin
    if (W <= 0) or (H <= 0) then Exit;
    Overlay := TBGRABitmap.Create(W, H);
    try
      Overlay.Fill(BGRA(40, 130, 235, 90));
      Overlay.Draw(ACanvas, X, Y, False);
    finally
      Overlay.Free;
    end;
  end;

begin
  if (not FDetectAreaEnabled) or (not FRollData.Loaded) or (FRollData.WidthPixels = 0) then Exit;

  scaleY   := FStripDisplayH / FRollData.WidthPixels;
  rowCount := (FPageStripCount + FStripsPerRow - 1) div FStripsPerRow;

  for row := 0 to rowCount - 1 do
  begin
    rowTopY    := FVGap + row * (FStripDisplayH + FVGap);
    rowBottomY := rowTopY + FStripDisplayH;

    ignoreTopY := rowTopY + Round(FDetectAreaTopPx * scaleY);
    if FDetectAreaTopPx > 0 then
    begin
      bandH := ignoreTopY - rowTopY;
      DrawBand(0, rowTopY, ClientWidth, bandH);
    end;

    ignoreBotY := rowBottomY - Round(FDetectAreaBottomPx * scaleY);
    if FDetectAreaBottomPx > 0 then
    begin
      bandH := rowBottomY - ignoreBotY;
      DrawBand(0, ignoreBotY, ClientWidth, bandH);
    end;

    ACanvas.Pen.Style := psSolid;
    ACanvas.Pen.Width := 2;
    ACanvas.Pen.Color := RGBToColor(40, 130, 235);
    ACanvas.Brush.Style := bsClear;

    ACanvas.MoveTo(0, ignoreTopY);
    ACanvas.LineTo(ClientWidth, ignoreTopY);
    ACanvas.MoveTo(0, ignoreBotY);
    ACanvas.LineTo(ClientWidth, ignoreBotY);
  end;

  ACanvas.Pen.Style := psSolid;
  ACanvas.Pen.Width := 1;
  ACanvas.Brush.Style := bsClear;
end;

procedure TStripView.PaintRubberBand(ACanvas: TCanvas);
{ Draws the rubber-band outline while the user is drawing a new frame. }
var
  X1, Y1, X2, Y2: Integer;
begin
  if FDragMode <> dmDrawNew then Exit;

  X1 := Min(FDragStartX, FRubberX2);
  Y1 := Min(FDragStartY, FRubberY2);
  X2 := Max(FDragStartX, FRubberX2);
  Y2 := Max(FDragStartY, FRubberY2);
  if (X2 - X1 < 3) and (Y2 - Y1 < 3) then Exit;

  ACanvas.Brush.Style := bsClear;
  ACanvas.Pen.Style   := psDash;
  ACanvas.Pen.Color   := clLime;
  ACanvas.Pen.Width   := 2;
  ACanvas.Rectangle(X1, Y1, X2, Y2);
  ACanvas.Pen.Style   := psSolid;
  ACanvas.Pen.Width   := 1;
end;

{ ============================================================ }
{ Stacked-frame cycling helpers                                 }
{ ============================================================ }

procedure TStripView.ResetCycle;
begin
  FCycleIndex := -1;
  FCycleX     := -1;
  FCycleY     := -1;
  SetLength(FCycleHits, 0);
end;

procedure TStripView.CollectHitsAtPoint(X, Y: Integer; out Hits: TIntArr);
{ Returns all frame indices whose screen rect contains (X,Y), sorted by
  area ascending (smallest = most specific first).  Mirrors HitTestFrame
  but collects every match instead of just the best. }
var
  i, S, S1, S2: Integer;
  F: TFrameRecord;
  StripR: TRect;
  PreviewH, PreviewW: Integer;
  ScaleX, ScaleY: Double;
  LocalLeadY, LocalTrailY, LocalLeft, LocalRight: Integer;
  FX1, FX2, FY1, FY2: Integer;
  HitCount: Integer;
  Areas: array of Int64;
  TmpI: Integer;
  TmpA: Int64;
begin
  SetLength(Hits, 0);
  if not FRollData.Loaded then Exit;

  PreviewW := Max(1, FRollData.WidthPixels div FRollData.PreviewDownScale);
  PreviewH := Max(1, FRollData.LengthLines div FRollData.PreviewDownScale);
  ScaleX   := FStripDisplayW / PreviewH;
  ScaleY   := FStripDisplayH / PreviewW;

  HitCount := 0;
  SetLength(Hits,  Length(FFrames));
  SetLength(Areas, Length(FFrames));

  for i := 0 to High(FFrames) do
  begin
    F  := FFrames[i];
    S1 := FrameLeadStrip(F, FRollData.LengthLines);
    S2 := FrameTrailStrip(F, FRollData.LengthLines);
    if (S2 < FFirstStrip) or (S1 > FFirstStrip + FPageStripCount - 1) then Continue;

    for S := Max(S1, FFirstStrip) to Min(S2, FFirstStrip + FPageStripCount - 1) do
    begin
      StripR := StripRect(S - FFirstStrip);

      LocalLeft  := Round(F.LeftEdge  / FRollData.PreviewDownScale);
      LocalRight := Round(F.RightEdge / FRollData.PreviewDownScale);

      if S = S1 then
        LocalLeadY := Integer(F.LeadEdge  mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalLeadY := 0;
      if S = S2 then
        LocalTrailY := Integer(F.TrailEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalTrailY := PreviewH;

      FX1 := StripR.Left + Round(LocalLeadY  * ScaleX);
      FX2 := StripR.Left + Round(LocalTrailY * ScaleX);
      FY1 := StripR.Top  + Round(LocalLeft   * ScaleY);
      FY2 := StripR.Top  + Round(LocalRight  * ScaleY);

      if (X >= FX1) and (X <= FX2) and (Y >= FY1) and (Y <= FY2) then
      begin
        Hits[HitCount]  := i;
        Areas[HitCount] := Int64(FX2 - FX1) * Int64(FY2 - FY1);
        Inc(HitCount);
        Break;   { count this frame once even if it spans multiple strips }
      end;
    end;
  end;

  SetLength(Hits,  HitCount);
  SetLength(Areas, HitCount);

  { Insertion sort by area ascending (smallest = most specific first) }
  for i := 1 to HitCount - 1 do
  begin
    TmpI := Hits[i];
    TmpA := Areas[i];
    S    := i - 1;
    while (S >= 0) and (Areas[S] > TmpA) do
    begin
      Hits[S + 1]  := Hits[S];
      Areas[S + 1] := Areas[S];
      Dec(S);
    end;
    Hits[S + 1]  := TmpI;
    Areas[S + 1] := TmpA;
  end;
end;

{ ============================================================ }
{ Drag handle helpers                                           }
{ ============================================================ }

function TStripView.HitHandleInRect(RX1, RY1, RX2, RY2, X, Y, HH: Integer;
                                     IsLeadSeg, IsTrailSeg: Boolean): TDragMode;

  function Near(CX, CY: Integer): Boolean;
  begin
    Result := (Abs(X - CX) <= HH) and (Abs(Y - CY) <= HH);
  end;

var
  MX, MY: Integer;
begin
  Result := dmNone;
  MX := (RX1 + RX2) div 2;
  MY := (RY1 + RY2) div 2;

  { Lead-side handles (left edge → LeadEdge in film coords) }
  if IsLeadSeg then
  begin
    if Near(RX1, RY1) then Exit(dmResizeLeadLeft);
    if Near(RX1, MY)  then Exit(dmResizeLead);
    if Near(RX1, RY2) then Exit(dmResizeLeadRight);
  end;

  { Trail-side handles (right edge → TrailEdge in film coords) }
  if IsTrailSeg then
  begin
    if Near(RX2, RY1) then Exit(dmResizeTrailLeft);
    if Near(RX2, MY)  then Exit(dmResizeTrail);
    if Near(RX2, RY2) then Exit(dmResizeTrailRight);
  end;

  { Top / bottom middle handles (LeftEdge / RightEdge in film coords) }
  if Near(MX, RY1) then Exit(dmResizeLeft);
  if Near(MX, RY2) then Exit(dmResizeRight);

  { Frame interior → move }
  if (X >= RX1) and (X <= RX2) and (Y >= RY1) and (Y <= RY2) then
    Exit(dmMove);
end;

function TStripView.FrameHitHandle(FrameIdx, X, Y: Integer): TDragMode;
{ Mirrors PaintFrameOverlays merge logic to find handle rects for one frame. }
var
  F: TFrameRecord;
  S1, S2, S: Integer;
  StripR: TRect;
  PreviewH, PreviewW: Integer;
  ScaleX, ScaleY: Double;
  LocalLeadY, LocalTrailY, LocalLeft, LocalRight: Integer;
  FX1, FX2, FY1, FY2: Integer;
  MergeX1, MergeX2, MergeY1, MergeY2: Integer;
  MergeStarted, bFlush, bIsFirstSeg: Boolean;
  SRow, SNextRow: Integer;
  LastStripOnPage: Integer;
begin
  Result := dmNone;
  if not FRollData.Loaded then Exit;

  F  := FFrames[FrameIdx];
  S1 := FrameLeadStrip(F, FRollData.LengthLines);
  S2 := FrameTrailStrip(F, FRollData.LengthLines);

  LastStripOnPage := FFirstStrip + FPageStripCount - 1;
  if (S2 < FFirstStrip) or (S1 > LastStripOnPage) then Exit;

  PreviewW := Max(1, FRollData.WidthPixels div FRollData.PreviewDownScale);
  PreviewH := Max(1, FRollData.LengthLines div FRollData.PreviewDownScale);
  ScaleX   := FStripDisplayW / PreviewH;
  ScaleY   := FStripDisplayH / PreviewW;

  LocalLeft  := Round(F.LeftEdge  / FRollData.PreviewDownScale);
  LocalRight := Round(F.RightEdge / FRollData.PreviewDownScale);

  MergeStarted := False;
  MergeX1 := 0; MergeX2 := 0; MergeY1 := 0; MergeY2 := 0;
  bIsFirstSeg := True;

  for S := Max(S1, FFirstStrip) to Min(S2, LastStripOnPage) do
  begin
    StripR := StripRect(S - FFirstStrip);

    if S = S1 then
      LocalLeadY := Integer(F.LeadEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
    else
      LocalLeadY := 0;
    if S = S2 then
      LocalTrailY := Integer(F.TrailEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
    else
      LocalTrailY := PreviewH;

    FX1 := Max(StripR.Left + Round(LocalLeadY  * ScaleX), StripR.Left);
    FX2 := Min(StripR.Left + Round(LocalTrailY * ScaleX), StripR.Right);
    FY1 := Max(StripR.Top  + Round(LocalLeft   * ScaleY), StripR.Top);
    FY2 := Min(StripR.Top  + Round(LocalRight  * ScaleY), StripR.Bottom);

    SRow := (S - FFirstStrip) div FStripsPerRow;

    if not MergeStarted then
    begin
      MergeX1 := FX1; MergeX2 := FX2;
      MergeY1 := FY1; MergeY2 := FY2;
      MergeStarted := True;
    end
    else
    begin
      MergeX2 := FX2;
      MergeY1 := Min(MergeY1, FY1);
      MergeY2 := Max(MergeY2, FY2);
    end;

    bFlush := (S = Min(S2, LastStripOnPage));
    if not bFlush then
    begin
      SNextRow := (S + 1 - FFirstStrip) div FStripsPerRow;
      bFlush := (SNextRow <> SRow);
    end;

    if bFlush and MergeStarted then
    begin
      if (MergeX2 > MergeX1) and (MergeY2 > MergeY1) then
      begin
        Result := HitHandleInRect(MergeX1, MergeY1, MergeX2, MergeY2,
                                  X, Y, HANDLE_HALF, bIsFirstSeg, S >= S2);
        if Result <> dmNone then Exit;
      end;
      MergeStarted := False;
      bIsFirstSeg  := False;
    end;
  end;
end;

procedure TStripView.ApplyDrag(X, Y: Integer);
{ Recomputes frame edges from current mouse position relative to drag start. }
var
  dX, dY: Integer;
  dLead: Int64;
  dLeft: Int64;
  newLead, newTrail: Int64;
  newLeft, newRight: Int64;
  MaxTrail: Int64;
  k: Integer;
begin
  if (FDragMode = dmNone) or (FDragFrameIdx < 0) then Exit;

  dX := X - FDragStartX;
  dY := Y - FDragStartY;

  { Convert screen delta → full-res film coordinate delta.
    ScaleX = FStripDisplayW / PreviewH = FStripDisplayW / (LengthLines / PreviewDownScale)
    dLead_fullres = dX / ScaleX * PreviewDownScale = dX * LengthLines / FStripDisplayW }
  if FStripDisplayW > 0 then
    dLead := Round(Int64(dX) * FRollData.LengthLines / FStripDisplayW)
  else
    dLead := 0;
  if FStripDisplayH > 0 then
    dLeft := Round(Int64(dY) * FRollData.WidthPixels / FStripDisplayH)
  else
    dLeft := 0;

  newLead  := FDragStartLead;
  newTrail := FDragStartTrail;
  newLeft  := FDragStartLeft;
  newRight := FDragStartRight;

  case FDragMode of
    dmMove:
    begin
      newLead  := FDragStartLead  + dLead;
      newTrail := FDragStartTrail + dLead;
      newLeft  := FDragStartLeft  + dLeft;
      newRight := FDragStartRight + dLeft;
    end;
    dmResizeLead:       newLead  := FDragStartLead  + dLead;
    dmResizeTrail:      newTrail := FDragStartTrail + dLead;
    dmResizeLeft:       newLeft  := FDragStartLeft  + dLeft;
    dmResizeRight:      newRight := FDragStartRight + dLeft;
    dmResizeLeadLeft:   begin newLead  := FDragStartLead  + dLead; newLeft  := FDragStartLeft  + dLeft; end;
    dmResizeLeadRight:  begin newLead  := FDragStartLead  + dLead; newRight := FDragStartRight + dLeft; end;
    dmResizeTrailLeft:  begin newTrail := FDragStartTrail + dLead; newLeft  := FDragStartLeft  + dLeft; end;
    dmResizeTrailRight: begin newTrail := FDragStartTrail + dLead; newRight := FDragStartRight + dLeft; end;
  end;

  { Clamp to roll bounds }
  MaxTrail := Int64(FRollData.StripCount) * FRollData.LengthLines - 1;
  if newLead  < 0        then newLead  := 0;
  if newTrail > MaxTrail then newTrail := MaxTrail;
  if newLeft  < 0        then newLeft  := 0;
  if newRight > FRollData.WidthPixels then newRight := FRollData.WidthPixels;

  { Ensure lead < trail and left < right (minimum 1 px) }
  if newLead >= newTrail then
  begin
    if dLead >= 0 then newLead  := newTrail - 1
    else               newTrail := newLead  + 1;
  end;
  if newLeft >= newRight then
  begin
    if dLeft >= 0 then newLeft  := newRight - 1
    else               newRight := newLeft  + 1;
  end;

  if FMultiManipulate and (Length(FMultiDragArr) > 1) then
  begin
    { Apply the same delta to every selected frame using its saved start values }
    for k := 0 to High(FMultiDragArr) do
    begin
      with FMultiDragArr[k] do
      begin
        newLead  := Lead;
        newTrail := Trail;
        newLeft  := Left;
        newRight := Right;
      end;

      case FDragMode of
        dmMove:
        begin
          newLead  := FMultiDragArr[k].Lead  + dLead;
          newTrail := FMultiDragArr[k].Trail + dLead;
          newLeft  := FMultiDragArr[k].Left  + dLeft;
          newRight := FMultiDragArr[k].Right + dLeft;
        end;
        dmResizeLead:       newLead  := FMultiDragArr[k].Lead  + dLead;
        dmResizeTrail:      newTrail := FMultiDragArr[k].Trail + dLead;
        dmResizeLeft:       newLeft  := FMultiDragArr[k].Left  + dLeft;
        dmResizeRight:      newRight := FMultiDragArr[k].Right + dLeft;
        dmResizeLeadLeft:   begin newLead  := FMultiDragArr[k].Lead  + dLead; newLeft  := FMultiDragArr[k].Left  + dLeft; end;
        dmResizeLeadRight:  begin newLead  := FMultiDragArr[k].Lead  + dLead; newRight := FMultiDragArr[k].Right + dLeft; end;
        dmResizeTrailLeft:  begin newTrail := FMultiDragArr[k].Trail + dLead; newLeft  := FMultiDragArr[k].Left  + dLeft; end;
        dmResizeTrailRight: begin newTrail := FMultiDragArr[k].Trail + dLead; newRight := FMultiDragArr[k].Right + dLeft; end;
      end;

      { Clamp per-frame }
      if newLead  < 0        then newLead  := 0;
      if newTrail > MaxTrail then newTrail := MaxTrail;
      if newLeft  < 0        then newLeft  := 0;
      if newRight > FRollData.WidthPixels then newRight := FRollData.WidthPixels;
      if newLead >= newTrail then
        if dLead >= 0 then newLead  := newTrail - 1
        else               newTrail := newLead  + 1;
      if newLeft >= newRight then
        if dLeft >= 0 then newLeft  := newRight - 1
        else               newRight := newLeft  + 1;

      FFrames[FMultiDragArr[k].Idx].LeadEdge  := newLead;
      FFrames[FMultiDragArr[k].Idx].TrailEdge := newTrail;
      FFrames[FMultiDragArr[k].Idx].LeftEdge  := Integer(newLeft);
      FFrames[FMultiDragArr[k].Idx].RightEdge := Integer(newRight);
    end;
  end
  else
  begin
    { Single-frame apply }
    FFrames[FDragFrameIdx].LeadEdge  := newLead;
    FFrames[FDragFrameIdx].TrailEdge := newTrail;
    FFrames[FDragFrameIdx].LeftEdge  := Integer(newLeft);
    FFrames[FDragFrameIdx].RightEdge := Integer(newRight);
  end;

  Invalidate;
end;

procedure TStripView.PaintBackground(ACanvas: TCanvas);
begin
  ACanvas.Brush.Color := Color;
  ACanvas.FillRect(ClientRect);
end;

procedure TStripView.PaintStrips(ACanvas: TCanvas);
var
  i, StripIdx: Integer;
  R: TRect;
  NumStr: String;
begin
  for i := 0 to FPageStripCount - 1 do
  begin
    StripIdx := FFirstStrip + i;
    R := StripRect(i);

    if (i < Length(FBitmaps)) and (FBitmaps[i] <> nil) then
    begin
      ACanvas.StretchDraw(R, FBitmaps[i]);
    end
    else
    begin
      { Placeholder for missing / not‑yet‑loaded strip }
      ACanvas.Brush.Color := $303030;
      ACanvas.Pen.Color   := $505050;
      ACanvas.Pen.Width   := 1;
      ACanvas.Rectangle(R);
      ACanvas.Font.Color  := $808080;
      ACanvas.Font.Size   := 8;
      NumStr := IntToStr(StripIdx);
      ACanvas.TextOut(R.Left + 2, R.Top + 2, NumStr);
    end;

    { Strip-edge overlay: a thin bright line at the right edge of each strip
      so the user can see exactly where one preview file ends and the next begins. }
    if FShowStripEdges then
    begin
      ACanvas.Pen.Color := $0000A0FF;  // orange (R=FF G=A0 B=00)
      ACanvas.Pen.Width := 1;
      ACanvas.MoveTo(R.Right - 1, R.Top);
      ACanvas.LineTo(R.Right - 1, R.Bottom);
    end;
  end;
end;

procedure TStripView.DrawFrameRect(ACanvas: TCanvas; const R: TRect;
                                   MainColor: TColor;
                                   IsMarker, IsSuggested: Boolean;
                                   IsExported: Boolean;
                                   HasPerFrameAdjustment: Boolean;
                                   ShowHandles: Boolean;
                                   IsLeadSeg: Boolean;
                                   IsTrailSeg: Boolean);
var
  MX, MY: Integer;
  HH: Integer;
  FillColor: TColor;
  FillPct: Integer;
  Overlay: TBGRABitmap;
  RGBColor: LongInt;
  FillAlpha: Byte;

  procedure DrawHandle(CX, CY: Integer);
  begin
    ACanvas.Rectangle(CX - HH, CY - HH, CX + HH, CY + HH);
  end;

begin
  ACanvas.Pen.Style   := psSolid;   { defensive: PaintTrimOverlay may leave psClear }
  ACanvas.Brush.Style := bsClear;

  if (FFrameFillOpacity > 0) and (R.Right > R.Left) and (R.Bottom > R.Top) then
  begin
    if IsMarker then
      FillColor := COL_FRAME_MARKER
    else if IsSuggested then
      FillColor := COL_FRAME_SUGGESTED
    else
      FillColor := MainColor;

    FillPct := Max(0, Min(100, FFrameFillOpacity));
    RGBColor := ColorToRGB(FillColor);
    FillAlpha := Round(FillPct * 180 / 100);
    Overlay := TBGRABitmap.Create(R.Right - R.Left, R.Bottom - R.Top);
    try
      Overlay.Fill(BGRA(RGBColor and $FF,
                        (RGBColor shr 8) and $FF,
                        (RGBColor shr 16) and $FF,
                        FillAlpha));
      Overlay.Draw(ACanvas, R.Left, R.Top, False);
    finally
      Overlay.Free;
    end;
  end;

  if IsExported and (R.Right > R.Left) and (R.Bottom > R.Top) then
  begin
    RGBColor := ColorToRGB(COL_FRAME_EXPORTED);
    FillAlpha := 70;
    Overlay := TBGRABitmap.Create(R.Right - R.Left, R.Bottom - R.Top);
    try
      Overlay.Fill(BGRA(RGBColor and $FF,
                        (RGBColor shr 8) and $FF,
                        (RGBColor shr 16) and $FF,
                        FillAlpha));
      Overlay.Draw(ACanvas, R.Left, R.Top, False);
    finally
      Overlay.Free;
    end;
  end;

  { Per-frame image/process overrides get an orange accent without replacing
    marker/suggested/selected meaning. }
  if HasPerFrameAdjustment then
  begin
    ACanvas.Pen.Color := COL_FRAME_PERFRAME;
    ACanvas.Pen.Width := 3;
    ACanvas.Rectangle(R.Left - 5, R.Top - 5, R.Right + 5, R.Bottom + 5);
  end;

  { Exported frames get a blue completion accent without replacing marker,
    per-frame, or selected meanings. }
  if IsExported then
  begin
    ACanvas.Pen.Color := COL_FRAME_EXPORTED;
    ACanvas.Pen.Width := 2;
    ACanvas.Rectangle(R.Left + 4, R.Top + 4, R.Right - 4, R.Bottom - 4);
  end;

  { Suggested frames: draw a prominent magenta outer ring before the main rect }
  if IsSuggested and not IsMarker then
  begin
    { Outer glow ring }
    ACanvas.Pen.Color := COL_FRAME_SUGGESTED;
    ACanvas.Pen.Width := 3;
    ACanvas.Rectangle(R.Left - 3, R.Top - 3, R.Right + 3, R.Bottom + 3);
    { Inner accent ring }
    ACanvas.Pen.Width := 1;
    ACanvas.Rectangle(R.Left + 3, R.Top + 3, R.Right - 3, R.Bottom - 3);
  end;

  { Main border }
  ACanvas.Pen.Width := FRAME_PEN_W;
  ACanvas.Pen.Color := MainColor;
  ACanvas.Rectangle(R);

  { Yellow overlay for markers }
  if IsMarker then
  begin
    ACanvas.Pen.Color := COL_FRAME_MARKER;
    ACanvas.Pen.Width := FRAME_PEN_W + 1;
    ACanvas.Rectangle(R.Left - 1, R.Top - 1, R.Right + 1, R.Bottom + 1);
  end;

  { Drag handles – white squares with black border on selected frames }
  if ShowHandles then
  begin
    HH := HANDLE_HALF;
    MX := (R.Left + R.Right)  div 2;
    MY := (R.Top  + R.Bottom) div 2;

    ACanvas.Pen.Color   := clBlack;
    ACanvas.Pen.Width   := 1;
    ACanvas.Brush.Color := clWhite;
    ACanvas.Brush.Style := bsSolid;

    { Lead-side handles (left edge of displayed rect = LeadEdge) }
    if IsLeadSeg then
    begin
      DrawHandle(R.Left, R.Top);     // top-left    → resize Lead + Left
      DrawHandle(R.Left, MY);        // mid-left    → resize Lead only
      DrawHandle(R.Left, R.Bottom);  // bottom-left → resize Lead + Right
    end;

    { Trail-side handles (right edge of displayed rect = TrailEdge) }
    if IsTrailSeg then
    begin
      DrawHandle(R.Right, R.Top);    // top-right    → resize Trail + Left
      DrawHandle(R.Right, MY);       // mid-right    → resize Trail only
      DrawHandle(R.Right, R.Bottom); // bottom-right → resize Trail + Right
    end;

    { Top / bottom middle handles (LeftEdge / RightEdge) – always drawn }
    DrawHandle(MX, R.Top);           // top-mid    → resize Left edge only
    DrawHandle(MX, R.Bottom);        // bottom-mid → resize Right edge only

    ACanvas.Brush.Style := bsClear;
  end;
end;

procedure TStripView.DrawSplitPreviewCuts(ACanvas: TCanvas; const F: TFrameRecord;
  ScaleX, ScaleY: Double);
var
  k, N, S, LastStripOnPage: Integer;
  CutLine, PartH: Int64;
  StripR: TRect;
  LocalY, LocalLeft, LocalRight: Integer;
  X, Y1, Y2: Integer;
begin
  if not FSplitPreviewEnabled then Exit;
  if not F.IsSelected then Exit;
  N := FSplitPreviewParts;
  if N < 2 then Exit;
  PartH := (F.TrailEdge - F.LeadEdge) div N;
  if PartH < 1 then Exit;

  LastStripOnPage := FFirstStrip + FPageStripCount - 1;
  LocalLeft  := Round(F.LeftEdge  / FRollData.PreviewDownScale);
  LocalRight := Round(F.RightEdge / FRollData.PreviewDownScale);

  ACanvas.Pen.Color := clWhite;
  ACanvas.Pen.Width := 2;
  ACanvas.Pen.Style := psDash;
  ACanvas.Brush.Style := bsClear;

  for k := 1 to N - 1 do
  begin
    CutLine := F.LeadEdge + k * PartH;
    S := Integer(CutLine div FRollData.LengthLines);
    if (S < FFirstStrip) or (S > LastStripOnPage) then Continue;

    StripR := StripRect(S - FFirstStrip);
    LocalY := Integer(CutLine mod FRollData.LengthLines) div FRollData.PreviewDownScale;

    X  := StripR.Left + Round(LocalY * ScaleX);
    Y1 := StripR.Top  + Round(LocalLeft * ScaleY);
    Y2 := StripR.Top  + Round(LocalRight * ScaleY);

    X  := Max(StripR.Left, Min(StripR.Right, X));
    Y1 := Max(StripR.Top,  Min(StripR.Bottom, Y1));
    Y2 := Max(StripR.Top,  Min(StripR.Bottom, Y2));

    if Y2 > Y1 then
    begin
      ACanvas.MoveTo(X, Y1);
      ACanvas.LineTo(X, Y2);
      ACanvas.Pen.Style := psSolid;
      ACanvas.Pen.Width := 1;
      ACanvas.Pen.Color := clBlack;
      ACanvas.MoveTo(X + 1, Y1);
      ACanvas.LineTo(X + 1, Y2);
      ACanvas.Pen.Color := clWhite;
      ACanvas.Pen.Width := 2;
      ACanvas.Pen.Style := psDash;
    end;
  end;

  ACanvas.Pen.Style := psSolid;
end;

procedure TStripView.PaintFrameOverlays(ACanvas: TCanvas);
var
  i, S, S1, S2: Integer;
  F: TFrameRecord;
  StripR: TRect;
  PreviewH, PreviewW: Integer;
  ScaleX, ScaleY: Double;
  LocalLeadY, LocalTrailY, LocalLeft, LocalRight: Integer;
  FX1, FX2, FY1, FY2: Integer;
  FR: TRect;
  MainColor: TColor;
  LastStripOnPage: Integer;
  SRow, SNextRow: Integer;
  MergeX1, MergeX2, MergeY1, MergeY2: Integer;
  MergeStarted, bFlush, bIsFirstSeg: Boolean;
begin
  if not FRollData.Loaded then Exit;
  if Length(FFrames) = 0   then Exit;

  PreviewW := Max(1, FRollData.WidthPixels div FRollData.PreviewDownScale);
  PreviewH := Max(1, FRollData.LengthLines div FRollData.PreviewDownScale);
  { After CW+HFlip the transform is a transpose: orig(x,y) → display(y,x).
    ScaleX = FStripDisplayW / PreviewH  (original Y axis → screen X)
    ScaleY = FStripDisplayH / PreviewW  (original X axis → screen Y) }
  ScaleX := FStripDisplayW / PreviewH;
  ScaleY := FStripDisplayH / PreviewW;

  LastStripOnPage := FFirstStrip + FPageStripCount - 1;

  ACanvas.Brush.Style := bsClear;

  for i := 0 to High(FFrames) do
  begin
    F  := FFrames[i];
    S1 := FrameLeadStrip(F, FRollData.LengthLines);
    S2 := FrameTrailStrip(F, FRollData.LengthLines);

    if (S2 < FFirstStrip) or (S1 > LastStripOnPage) then Continue;

    if F.IsSelected then
      MainColor := COL_FRAME_SELECTED
    else if F.IsOversized or F.IsUndersized then
      MainColor := COL_FRAME_ABNORMAL
    else
      MainColor := COL_FRAME_NORMAL;

    LocalLeft  := Round(F.LeftEdge  / FRollData.PreviewDownScale);
    LocalRight := Round(F.RightEdge / FRollData.PreviewDownScale);

    { Accumulate per-strip segments into merged row-groups so that strips
      sitting side-by-side in the same display row are drawn as ONE rect.
      Strips on different rows (row-wrap) are still drawn separately. }
    MergeStarted := False;
    MergeX1 := 0; MergeX2 := 0; MergeY1 := 0; MergeY2 := 0;
    bIsFirstSeg := True;

    for S := Max(S1, FFirstStrip) to Min(S2, LastStripOnPage) do
    begin
      StripR := StripRect(S - FFirstStrip);

      if S = S1 then
        LocalLeadY := Integer(F.LeadEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalLeadY := 0;

      if S = S2 then
        LocalTrailY := Integer(F.TrailEdge mod FRollData.LengthLines) div FRollData.PreviewDownScale
      else
        LocalTrailY := PreviewH;

      FX1 := StripR.Left + Round(LocalLeadY  * ScaleX);
      FX2 := StripR.Left + Round(LocalTrailY * ScaleX);
      FY1 := StripR.Top  + Round(LocalLeft   * ScaleY);
      FY2 := StripR.Top  + Round(LocalRight  * ScaleY);

      FX1 := Max(FX1, StripR.Left);
      FX2 := Min(FX2, StripR.Right);
      FY1 := Max(FY1, StripR.Top);
      FY2 := Min(FY2, StripR.Bottom);

      SRow := (S - FFirstStrip) div FStripsPerRow;

      if not MergeStarted then
      begin
        MergeX1 := FX1; MergeX2 := FX2;
        MergeY1 := FY1; MergeY2 := FY2;
        MergeStarted := True;
      end
      else
      begin
        { Extend merged rect rightward along the same row }
        MergeX2 := FX2;
        MergeY1 := Min(MergeY1, FY1);
        MergeY2 := Max(MergeY2, FY2);
      end;

      { Flush (draw) when: last strip in frame on page, OR next strip wraps
        to a new display row }
      bFlush := (S = Min(S2, LastStripOnPage));
      if not bFlush then
      begin
        SNextRow := (S + 1 - FFirstStrip) div FStripsPerRow;
        bFlush := (SNextRow <> SRow);
      end;

      if bFlush and MergeStarted then
      begin
        if (MergeX2 > MergeX1) and (MergeY2 > MergeY1) then
        begin
          FR := Rect(MergeX1, MergeY1, MergeX2, MergeY2);
          { IsTrailSeg: this segment contains the actual trail edge of the frame }
          DrawFrameRect(ACanvas, FR, MainColor, F.IsMarker, F.IsSuggested,
                        F.IsExported,
                        (F.PerFrameBrightness <> -1) or
                        (F.PerFrameContrast <> -1) or
                        (F.PerFrameGamma <> -1) or
                        (F.CustomBrightness <> -1) or
                        (F.CustomContrast <> -1) or
                        (F.CustomGamma <> -1) or
                        F.HasOverride,
                        F.IsSelected,   { ShowHandles }
                        bIsFirstSeg,    { IsLeadSeg  }
                        S >= S2);       { IsTrailSeg }
        end;
        MergeStarted := False;
        bIsFirstSeg  := False;
      end;
    end;

    DrawSplitPreviewCuts(ACanvas, F, ScaleX, ScaleY);
  end;
end;

procedure TStripView.Paint;
begin
  PaintBackground(Canvas);
  PaintStrips(Canvas);
  PaintDetectRangeOverlay(Canvas);
  PaintDetectionAreaOverlay(Canvas);
  PaintTrimOverlay(Canvas);      { yellow bands before frame outlines }
  PaintFrameOverlays(Canvas);
  PaintRubberBand(Canvas);       { rubber-band on top of everything }
end;

{ ============================================================ }
{ Resize                                                        }
{ ============================================================ }

procedure TStripView.Resize;
begin
  inherited Resize;
  RecalcLayout;
  Invalidate;
end;

{ ============================================================ }
{ Mouse events                                                  }
{ ============================================================ }

procedure TStripView.MouseDown(Button: TMouseButton; Shift: TShiftState;
                                X, Y: Integer);
var
  FrameIdx: Integer;
  i, j: Integer;
  Mode: TDragMode;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then SetFocus;
  if FRollData.Loaded and (Button = mbRight) then
  begin
    ShowContextMenuAt(X, Y);
    Exit;
  end;
  if not FRollData.Loaded then Exit;

  { ── Priority 0: trim-line drag (plain left click near a trim line) ─────── }
  if (Button = mbLeft) and (Shift * [ssShift, ssCtrl] = []) then
  begin
    Mode := DetectRangeHitTest(X, Y);
    if Mode in [dmDetectStart, dmDetectEnd] then
    begin
      FDragMode     := Mode;
      FDragFrameIdx := -1;
      FDragStartX   := X;
      FDragStartY   := Y;
      Exit;
    end;

    Mode := DetectAreaHitTest(Y);
    if Mode in [dmDetectAreaTop, dmDetectAreaBottom] then
    begin
      FDragMode     := Mode;
      FDragFrameIdx := -1;
      FDragStartX   := X;
      FDragStartY   := Y;
      Exit;
    end;

    Mode := TrimHitTest(Y);
    if Mode in [dmTrimTop, dmTrimBottom] then
    begin
      FDragMode     := Mode;
      FDragFrameIdx := -1;
      FDragStartX   := X;
      FDragStartY   := Y;
      Exit;
    end;
  end;

  { ── Priority 1: drag handle on a selected frame ────────────────────────── }
  if (Button = mbLeft) and (Shift * [ssShift, ssCtrl] = []) then
  begin
    for i := 0 to High(FFrames) do
    begin
      if not FFrames[i].IsSelected then Continue;
      Mode := FrameHitHandle(i, X, Y);
      if Mode <> dmNone then
      begin
        FDragMode       := Mode;
        FDragFrameIdx   := i;
        FDragStartX     := X;
        FDragStartY     := Y;
        FDragStartLead  := FFrames[i].LeadEdge;
        FDragStartTrail := FFrames[i].TrailEdge;
        FDragStartLeft  := FFrames[i].LeftEdge;
        FDragStartRight := FFrames[i].RightEdge;

        { Save start state for ALL selected frames when multi-manipulate is on }
        if FMultiManipulate then
        begin
          SetLength(FMultiDragArr, 0);
          for j := 0 to High(FFrames) do
            if FFrames[j].IsSelected then
            begin
              SetLength(FMultiDragArr, Length(FMultiDragArr) + 1);
              with FMultiDragArr[High(FMultiDragArr)] do
              begin
                Idx   := j;
                Lead  := FFrames[j].LeadEdge;
                Trail := FFrames[j].TrailEdge;
                Left  := FFrames[j].LeftEdge;
                Right := FFrames[j].RightEdge;
              end;
            end;
        end;

        Exit;  { consume event – skip normal selection }
      end;
    end;
  end;

  { ── Priority 2: Shift / Ctrl modified clicks – standard range/toggle ──── }
  if ssShift in Shift then
  begin
    FrameIdx := HitTestFrame(X, Y);
    if FrameIdx >= 0 then
    begin
      if SelectionAnchorCanExtend then
      begin
        for i := 0 to High(FFrames) do
          if (i >= Min(FSelectionAnchor, FrameIdx)) and
             (i <= Max(FSelectionAnchor, FrameIdx)) then
            FFrames[i].IsSelected := True;
      end
      else
      begin
        for i := 0 to High(FFrames) do FFrames[i].IsSelected := (i = FrameIdx);
        FSelectionAnchor := FrameIdx;
      end;
      ResetCycle;
      Invalidate;
      if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
    end;
    Exit;
  end;

  if ssCtrl in Shift then
  begin
    FrameIdx := HitTestFrame(X, Y);
    if FrameIdx >= 0 then
    begin
      FFrames[FrameIdx].IsSelected := not FFrames[FrameIdx].IsSelected;
      FSelectionAnchor := FrameIdx;
      ResetCycle;
      Invalidate;
      if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
    end;
    Exit;
  end;

  { ── Priority 3: plain left click – stacked-frame cycling ───────────────── }
  if Button = mbLeft then
  begin
    CollectHitsAtPoint(X, Y, FCycleHits);

    if Length(FCycleHits) = 0 then
    begin
      { Click on empty area: start rubber-band draw for new frame }
      FDragMode     := dmDrawNew;
      FDragFrameIdx := -1;
      FDragStartX   := X;
      FDragStartY   := Y;
      FRubberX2     := X;
      FRubberY2     := Y;
      { Don't deselect here – deselect only if rubber-band is too small in MouseUp }
      Exit;
    end
    else if Length(FCycleHits) = 1 then
    begin
      { Only one frame here – plain select, reset cycle }
      FrameIdx := FCycleHits[0];
      for i := 0 to High(FFrames) do FFrames[i].IsSelected := (i = FrameIdx);
      FSelectionAnchor := FrameIdx;
      FCycleX     := X;
      FCycleY     := Y;
      FCycleIndex := 0;
    end
    else
    begin
      { Multiple overlapping frames – cycle through them }
      if (FCycleIndex >= 0) and
         (Abs(X - FCycleX) <= CYCLE_THRESH) and
         (Abs(Y - FCycleY) <= CYCLE_THRESH) then
      begin
        { Same spot re-click: advance cycle }
        FCycleIndex := (FCycleIndex + 1) mod Length(FCycleHits);
      end
      else
      begin
        { Fresh spot: start new cycle at index 0 (smallest frame first) }
        FCycleX     := X;
        FCycleY     := Y;
        FCycleIndex := 0;
      end;

      FrameIdx := FCycleHits[FCycleIndex];
      for i := 0 to High(FFrames) do FFrames[i].IsSelected := (i = FrameIdx);
      FSelectionAnchor := FrameIdx;
    end;

    Invalidate;
    if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
  end;
end;

procedure TStripView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
  Mode: TDragMode;
begin
  inherited MouseMove(Shift, X, Y);

  { ── Active drag: update in real time ───────────────────────────────────── }
  case FDragMode of
    dmDrawNew:
    begin
      FRubberX2 := X;
      FRubberY2 := Y;
      Invalidate;
      Exit;
    end;
    dmTrimTop:
    begin
      { Convert Y delta to full-res pixels: dy * WidthPixels / FStripDisplayH }
      if FStripDisplayH > 0 then
        FTrimTopPx := Max(0, FTrimDragStartPx
                         + Round((Y - FDragStartY) * FRollData.WidthPixels / FStripDisplayH));
      Invalidate;
      if Assigned(FOnTrimChanged) then FOnTrimChanged(Self);
      Exit;
    end;
    dmTrimBottom:
    begin
      if FStripDisplayH > 0 then
        FTrimBottomPx := Max(0, FTrimDragStartPx
                            - Round((Y - FDragStartY) * FRollData.WidthPixels / FStripDisplayH));
      Invalidate;
      if Assigned(FOnTrimChanged) then FOnTrimChanged(Self);
      Exit;
    end;
    dmDetectAreaTop:
    begin
      if FStripDisplayH > 0 then
        SetDetectAreaTopPx(Max(0, FDetectAreaDragStartPx
                         + Round((Y - FDragStartY) * FRollData.WidthPixels / FStripDisplayH)));
      Invalidate;
      if Assigned(FOnDetectAreaChanged) then FOnDetectAreaChanged(Self);
      Exit;
    end;
    dmDetectAreaBottom:
    begin
      if FStripDisplayH > 0 then
        SetDetectAreaBottomPx(Max(0, FDetectAreaDragStartPx
                            - Round((Y - FDragStartY) * FRollData.WidthPixels / FStripDisplayH)));
      Invalidate;
      if Assigned(FOnDetectAreaChanged) then FOnDetectAreaChanged(Self);
      Exit;
    end;
    dmDetectStart:
    begin
      i := ScreenToDetectStrip(X, Y, False);
      if i >= 0 then
      begin
        FDetectStartStrip := Min(i, FDetectEndStrip);
        Invalidate;
        if Assigned(FOnDetectRangeChanged) then FOnDetectRangeChanged(Self);
      end;
      Exit;
    end;
    dmDetectEnd:
    begin
      i := ScreenToDetectStrip(X, Y, True);
      if i >= 0 then
      begin
        FDetectEndStrip := Max(i, FDetectStartStrip);
        Invalidate;
        if Assigned(FOnDetectRangeChanged) then FOnDetectRangeChanged(Self);
      end;
      Exit;
    end;
  end;

  { Frame resize / move drag }
  if FDragMode <> dmNone then
  begin
    ApplyDrag(X, Y);
    Exit;
  end;

  { ── Hover cursor ────────────────────────────────────────────────────────── }
  { Check trim lines first }
  if DetectRangeHitTest(X, Y) in [dmDetectStart, dmDetectEnd] then
  begin
    Cursor := crSizeWE;
    Exit;
  end;

  if TrimHitTest(Y) in [dmTrimTop, dmTrimBottom] then
  begin
    Cursor := crSizeNS;
    Exit;
  end;

  if DetectAreaHitTest(Y) in [dmDetectAreaTop, dmDetectAreaBottom] then
  begin
    Cursor := crSizeNS;
    Exit;
  end;

  { Check frame handles on selected frames }
  for i := 0 to High(FFrames) do
  begin
    if not FFrames[i].IsSelected then Continue;
    Mode := FrameHitHandle(i, X, Y);
    if Mode <> dmNone then
    begin
      case Mode of
        dmMove:
          Cursor := crSizeAll;
        dmResizeLead,
        dmResizeTrail:
          Cursor := crSizeWE;
        dmResizeLeft,
        dmResizeRight:
          Cursor := crSizeNS;
        dmResizeLeadLeft,
        dmResizeTrailRight:
          Cursor := crSizeNWSE;
        dmResizeLeadRight,
        dmResizeTrailLeft:
          Cursor := crSizeNESW;
      end;
      Exit;
    end;
  end;
  Cursor := crDefault;
end;

procedure TStripView.MouseUp(Button: TMouseButton; Shift: TShiftState;
                              X, Y: Integer);
var
  newF: TFrameRecord;
  L1, L2: Int64;
  T1, T2: Integer;
  ok1, ok2: Boolean;
  i: Integer;
  minW: Integer;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then Exit;

  case FDragMode of

    dmDrawNew:
    begin
      FRubberX2 := X;
      FRubberY2 := Y;
      minW := 10; { minimum rubber-band size in screen pixels to count as a new frame }

      if (Abs(X - FDragStartX) >= minW) and (Abs(Y - FDragStartY) >= minW) then
      begin
        ok1 := ScreenToFilm(Min(FDragStartX, FRubberX2), Min(FDragStartY, FRubberY2), L1, T1);
        ok2 := ScreenToFilm(Max(FDragStartX, FRubberX2), Max(FDragStartY, FRubberY2), L2, T2);

        if ok1 and ok2 and (L2 > L1) and (T2 > T1) then
        begin
          InitFrameRecord(newF, Length(FFrames));
          newF.LeadEdge  := L1;
          newF.TrailEdge := L2;
          newF.LeftEdge  := T1;
          newF.RightEdge := T2;
          SetLength(FFrames, Length(FFrames) + 1);
          FFrames[High(FFrames)] := newF;
          SortFramesByPosition(FFrames);
          CalculateFrameStats(FFrames, FFrameStats);
          MarkOversizedUndersized(FFrames, FFrameStats);
          if Assigned(FOnFrameChanged) then FOnFrameChanged(Self);
        end;
      end
      else
      begin
        { Tiny movement = treat as click → deselect all }
        for i := 0 to High(FFrames) do FFrames[i].IsSelected := False;
        FSelectionAnchor := -1;
        ResetCycle;
        if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
      end;

      FDragMode := dmNone;
      Cursor    := crDefault;
      Invalidate;
    end;

    dmTrimTop, dmTrimBottom:
    begin
      { Final trim update already applied in MouseMove; just finalize }
      FDragMode := dmNone;
      Cursor    := crDefault;
      if Assigned(FOnTrimChanged) then FOnTrimChanged(Self);
    end;

    dmDetectAreaTop, dmDetectAreaBottom:
    begin
      FDragMode := dmNone;
      Cursor    := crDefault;
      if Assigned(FOnDetectAreaChanged) then FOnDetectAreaChanged(Self);
    end;

    dmDetectStart, dmDetectEnd:
    begin
      FDragMode := dmNone;
      Cursor    := crDefault;
      if Assigned(FOnDetectRangeChanged) then FOnDetectRangeChanged(Self);
    end;

  else
    { Frame resize / move }
    if FDragMode <> dmNone then
    begin
      ApplyDrag(X, Y);
      FDragMode     := dmNone;
      FDragFrameIdx := -1;
      Cursor        := crDefault;
      SortFramesByPosition(FFrames);
      CalculateFrameStats(FFrames, FFrameStats);
      MarkOversizedUndersized(FFrames, FFrameStats);
      Invalidate;
      if Assigned(FOnFrameChanged) then FOnFrameChanged(Self);
    end;
  end;
end;

procedure TStripView.CancelInteraction;
begin
  FDragMode := dmNone;
  FDragFrameIdx := -1;
  SetLength(FMultiDragArr, 0);
  Cursor := crDefault;
  Invalidate;
end;

procedure TStripView.DblClick;
var
  X, Y: Integer;
  P: TPoint;
  FrameIdx: Integer;
begin
  inherited DblClick;
  P := ScreenToClient(Mouse.CursorPos);
  X := P.X; Y := P.Y;
  FrameIdx := HitTestFrame(X, Y);
  if (FrameIdx >= 0) and Assigned(FOnFrameDblClick) then
  begin
    CancelInteraction;
    SelectFrame(FrameIdx);
    FOnFrameDblClick(Self);
  end;
end;

{ ============================================================ }
{ Setters                                                       }
{ ============================================================ }

procedure TStripView.SetStripsPerRow(Value: Integer);
var
  KeepStrip, NewPage: Integer;
begin
  Value := Max(MIN_STRIPS_PER_ROW, Min(MAX_STRIPS_PER_ROW, Value));
  if Value = FStripsPerRow then Exit;
  KeepStrip := FFirstStrip;
  FStripsPerRow := Value;
  RecalcLayout;
  if FRollData.Loaded then
  begin
    NewPage := 0;
    if (FStripsPerRow > 0) and (FRowsPerPage > 0) then
      NewPage := KeepStrip div (FStripsPerRow * FRowsPerPage);
    FCurrentPage := -1;  { force page bitmap reload even if index stays the same }
    GotoPage(NewPage);
  end
  else
    GotoPage(0);
end;

procedure TStripView.SetZoom(Value: Double);
begin
  Value := Max(MIN_ZOOM, Min(MAX_ZOOM, Value));
  if Abs(Value - FZoom) < 0.001 then Exit;
  FZoom := Value;
  RecalcLayout;
  LoadPageBitmaps;
  Invalidate;
end;

procedure TStripView.SetCurrentPage(Value: Integer);
begin
  Value := Max(0, Min(GetTotalPages - 1, Value));
  if Value = FCurrentPage then Exit;
  FCurrentPage := Value;
  ResetCycle;
  LoadPageBitmaps;
  Invalidate;
  if Assigned(FOnPageChanged) then FOnPageChanged(Self);
end;

procedure TStripView.SetRotateCW(Value: Boolean);
begin
  if Value = FRotateCW then Exit;
  FRotateCW := Value;
  ClearBitmapCache;
  LoadPageBitmaps;   // reload with new rotation
  Invalidate;
end;

procedure TStripView.SetFrameFillOpacity(Value: Integer);
begin
  Value := Max(0, Min(100, Value));
  if Value = FFrameFillOpacity then Exit;
  FFrameFillOpacity := Value;
  Invalidate;
end;

procedure TStripView.SetSplitPreviewEnabled(Value: Boolean);
begin
  if Value = FSplitPreviewEnabled then Exit;
  FSplitPreviewEnabled := Value;
  Invalidate;
end;

procedure TStripView.SetSplitPreviewParts(Value: Integer);
begin
  Value := Max(2, Value);
  if Value = FSplitPreviewParts then Exit;
  FSplitPreviewParts := Value;
  Invalidate;
end;

procedure TStripView.SetDetectRangeEnabled(Value: Boolean);
begin
  if Value = FDetectRangeEnabled then Exit;
  FDetectRangeEnabled := Value;
  Invalidate;
end;

procedure TStripView.SetDetectStartStrip(Value: Integer);
begin
  if FRollData.Loaded then
    Value := Max(0, Min(Value, FRollData.StripCount - 1))
  else
    Value := Max(0, Value);
  if Value > FDetectEndStrip then FDetectEndStrip := Value;
  if Value = FDetectStartStrip then Exit;
  FDetectStartStrip := Value;
  Invalidate;
end;

procedure TStripView.SetDetectEndStrip(Value: Integer);
begin
  if FRollData.Loaded then
    Value := Max(0, Min(Value, FRollData.StripCount - 1))
  else
    Value := Max(0, Value);
  if Value < FDetectStartStrip then FDetectStartStrip := Value;
  if Value = FDetectEndStrip then Exit;
  FDetectEndStrip := Value;
  Invalidate;
end;

procedure TStripView.SetDetectAreaTopPx(Value: Integer);
begin
  if FRollData.Loaded then
    Value := Max(0, Min(Value, Max(0, FRollData.WidthPixels - FDetectAreaBottomPx - 1)))
  else
    Value := Max(0, Value);
  if Value = FDetectAreaTopPx then Exit;
  FDetectAreaTopPx := Value;
  Invalidate;
end;

procedure TStripView.SetDetectAreaBottomPx(Value: Integer);
begin
  if FRollData.Loaded then
    Value := Max(0, Min(Value, Max(0, FRollData.WidthPixels - FDetectAreaTopPx - 1)))
  else
    Value := Max(0, Value);
  if Value = FDetectAreaBottomPx then Exit;
  FDetectAreaBottomPx := Value;
  Invalidate;
end;

procedure TStripView.SetDetectAreaEnabled(Value: Boolean);
begin
  if Value = FDetectAreaEnabled then Exit;
  FDetectAreaEnabled := Value;
  Invalidate;
end;

{ ============================================================ }
{ Public interface                                              }
{ ============================================================ }

procedure TStripView.SetPreviewAdjustment(AContrast, ABrightness, AGamma: Integer; AMode: Integer;
  AFlags: Integer; AStrength: Integer; ANegative: Boolean);
begin
  if AMode = 1 then
  begin
    AContrast := Max(-128, Min(255, AContrast));
    ABrightness := Max(-128, Min(127, ABrightness));
    AGamma := Max(-255, Min(255, AGamma));
  end
  else if AMode = 4 then
  begin
    AContrast := Max(-128, Min(255, AContrast));
    ABrightness := Max(-128, Min(127, ABrightness));
    AGamma := Max(-255, Min(255, AGamma));
  end
  else if (AMode in [2, 3]) or ToneMethodIsAdaptive(AMode) then
  begin
    AContrast := Max(-100, Min(100, AContrast));
    ABrightness := Max(-100, Min(100, ABrightness));
    AGamma := Max(10, Min(300, AGamma));
  end
  else
  begin
    AMode := 0;
    AContrast := Max(-100, Min(100, AContrast));
    ABrightness := Max(-100, Min(100, ABrightness));
    AGamma := Max(10, Min(300, AGamma));
  end;

  if (AContrast = FPreviewContrast) and
     (ABrightness = FPreviewBrightness) and
     (AGamma = FPreviewGamma) and
     (AMode = FPreviewAdjustMode) and
     (AFlags = FPreviewAdjustFlags) and
     (AStrength = FPreviewStrength) and
     (ANegative = FPreviewNegative) then Exit;

  FPreviewContrast := AContrast;
  FPreviewBrightness := ABrightness;
  FPreviewGamma := AGamma;
  FPreviewAdjustMode := AMode;
  FPreviewAdjustFlags := AFlags;
  FPreviewStrength := AStrength;
  FPreviewNegative := ANegative;
  ClearBitmapCache;
  LoadPageBitmaps;
  Invalidate;
end;

procedure TStripView.LoadRoll(const ARoll: TRollData; const AFrames: TFrameList);
begin
  ClearBitmapCache;
  FRollData        := ARoll;
  FFrames          := AFrames;
  SortFramesByPosition(FFrames);
  FCurrentPage     := 0;
  FFirstStrip      := 0;
  FSelectionAnchor := -1;
  ResetCycle;
  CalculateFrameStats(FFrames, FFrameStats);
  MarkOversizedUndersized(FFrames, FFrameStats);
  RecalcLayout;
  LoadPageBitmaps;
  Invalidate;
  if Assigned(FOnPageChanged) then FOnPageChanged(Self);
end;

procedure TStripView.UpdateFrames(const AFrames: TFrameList);
begin
  FFrames := AFrames;
  SortFramesByPosition(FFrames);
  if not SelectionAnchorCanExtend then
    FSelectionAnchor := -1;
  ResetCycle;
  Invalidate;
end;

procedure TStripView.ClearRoll;
begin
  ClearBitmapCache;
  InitRollData(FRollData);
  SetLength(FFrames, 0);
  FCurrentPage     := 0;
  FFirstStrip      := 0;
  FSelectionAnchor := -1;
  ResetCycle;
  Invalidate;
  if Assigned(FOnPageChanged) then FOnPageChanged(Self);
end;

procedure TStripView.GotoPage(PageIndex: Integer);
begin
  SetCurrentPage(PageIndex);
end;

procedure TStripView.GotoFirst;
begin
  GotoPage(0);
end;

procedure TStripView.GotoLast;
begin
  GotoPage(Max(0, GetTotalPages - 1));
end;

procedure TStripView.GotoNext;
begin
  GotoPage(FCurrentPage + 1);
end;

procedure TStripView.GotoPrev;
begin
  GotoPage(FCurrentPage - 1);
end;

procedure TStripView.SelectAll;
var i: Integer;
begin
  for i := 0 to High(FFrames) do FFrames[i].IsSelected := True;
  ResetCycle;
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TStripView.SelectPage;
var i, S1, S2: Integer;
begin
  for i := 0 to High(FFrames) do
  begin
    S1 := FrameLeadStrip(FFrames[i], FRollData.LengthLines);
    S2 := FrameTrailStrip(FFrames[i], FRollData.LengthLines);
    FFrames[i].IsSelected := (S2 >= FFirstStrip) and
                              (S1 <= FFirstStrip + FPageStripCount - 1);
  end;
  ResetCycle;
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TStripView.SelectNone;
var i: Integer;
begin
  for i := 0 to High(FFrames) do FFrames[i].IsSelected := False;
  FSelectionAnchor := -1;
  ResetCycle;
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TStripView.ToggleMarker(FrameIndex: Integer);
begin
  if (FrameIndex < 0) or (FrameIndex > High(FFrames)) then Exit;
  FFrames[FrameIndex].IsMarker := not FFrames[FrameIndex].IsMarker;
  Invalidate;
end;

procedure TStripView.SelectFrame(FrameIndex: Integer);
var
  i: Integer;
begin
  if (FrameIndex < 0) or (FrameIndex > High(FFrames)) then Exit;
  for i := 0 to High(FFrames) do
    FFrames[i].IsSelected := (i = FrameIndex);
  FSelectionAnchor := FrameIndex;
  Invalidate;
  if Assigned(FOnSelectionChanged) then FOnSelectionChanged(Self);
end;

procedure TStripView.SetShowStripEdges(Value: Boolean);
begin
  if Value = FShowStripEdges then Exit;
  FShowStripEdges := Value;
  Invalidate;
end;

end.
