unit uMainForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, Dialogs,
  ComCtrls, StdCtrls, ExtCtrls, Buttons, Spin, Math, LCLType, Menus, FPWriteJPEG,
  BGRABitmap, BGRABitmapTypes,
  uTurboJPEG,
  uTypes, uIDFParser, uStripView, uQPF, uFrameDetect;

const
  STRIPLIGHT_VERSION = '48.5';
  STRIPLIGHT_TITLE = 'Striplight ' + STRIPLIGHT_VERSION;

type
  TMainForm = class;

  TExportOutcome = (eoExported, eoSkipped, eoFailed);

  TExportJob = record
    OrderIdx: Integer;
    FrameIdx: Integer;
    FolderPath: String;
    FullPath: String;
  end;

  TExportSettings = record
    Roll: TRollData;
    Frames: TFrameList;
    SourceRotateCW: Boolean;
    JpgQuality: Integer;
    JpgGrayscale: Boolean;
    JpgProgressive: Boolean;
    JpgEncoder: Integer;
    LocalTempStage: Boolean;
    CacheLimit: Integer;
    SkipExisting: Boolean;
    AllowPreviewFallback: Boolean;
    GlobalRotation: Integer;
    GlobalFlipH: Boolean;
    GlobalFlipV: Boolean;
    GlobalNegative: Boolean;
    GlobalMethod: Integer;
    GlobalFlags: Integer;
    GlobalContrast: Integer;
    GlobalBrightness: Integer;
    GlobalGamma: Integer;
    GlobalSharpness: Integer;
    GlobalSharpnessMode: Integer;
  end;

  TExportWorkerThread = class(TThread)
  private
    FOwner: TMainForm;
    FSettings: TExportSettings;
    FCache: TStringList;
    FRunId: Integer;
    FBatchNext: Integer;
    FBatchLast: Integer;
    FDoneFrameIdx: Integer;
    FDoneOrderIdx: Integer;
    FDoneOutcome: TExportOutcome;
    FDoneError: String;
    FDoneBuildMs: Int64;
    FDoneLoadMs: Int64;
    FDoneCropMs: Int64;
    FDoneAdjustMs: Int64;
    FDoneSaveMs: Int64;
    FDoneTotalMs: Int64;
    function ClampInt(Value, Lo, Hi: Integer): Integer;
    function CeilDiv64(Value, Divisor: Int64): Integer;
    function FrameStripFilesAvailable(const F: TFrameRecord; FirstStrip,
      LastStrip: Integer): Boolean;
    function CachedRawSource(const SourcePath: String; out Err: String): TBGRABitmap;
    procedure ClearSourceCache;
    procedure FreeSourceCache;
    procedure ResolveFrameProcessing(const F: TFrameRecord; out Rot: Integer;
      out FlipH, FlipV, Negative: Boolean; out Method, Flags, Contrast,
      Brightness, Gamma: Integer);
    procedure ApplyNegative(ABitmap: TBGRABitmap);
    procedure ApplyGrayAdjustment(ABitmap: TBGRABitmap; Method, Flags, Contrast,
      Brightness, Gamma: Integer);
    function AdjustmentIsNoOp(Method, Flags, Contrast, Brightness, Gamma: Integer): Boolean;
    function BuildFrameBitmap(FrameIdx: Integer; out ABitmap: TBGRABitmap;
      out Err: String; out LoadMs, CropMs, AdjustMs: Int64): Boolean;
    procedure SaveJpeg(ABitmap: TBGRABitmap; const Path: String);
    procedure SaveJpegStaged(ABitmap: TBGRABitmap; const Path: String);
    function ClaimNextJob(out Job: TExportJob): Boolean;
    function IsBitmapResourceError(const Err: String): Boolean;
    procedure TraceJob(const Stage: String; const Job: TExportJob;
      const Detail: String = '');
    procedure SyncJobDone;
    procedure SyncWorkerDone;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMainForm; const ASettings: TExportSettings);
    destructor Destroy; override;
  end;

  TPreviewCacheThread = class(TThread)
  private
    FOwner: TMainForm;
    FRoll: TRollData;
    FTotal: Integer;
    FCopied: Integer;
    FSkipped: Integer;
    FMissing: Integer;
    FCurrent: Integer;
    FStatus: String;
    function ProjectLabel: String;
    function PreviewSourceFolderPath: String;
    function PreviewSourcePath(StripIndex: Integer): String;
    function PreviewCachePath(StripIndex: Integer): String;
    procedure CopyOneFile(const SourceFile, DestFile: String);
    procedure SyncProgress;
    procedure SyncDone;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMainForm; const ARoll: TRollData);
  end;

  TCacheScanThread = class(TThread)
  private
    FOwner: TMainForm;
    FRoots: TStringList;
    FFound: TStringList;
    FCurrent: String;
    FScannedFolders: Integer;
    FScannedFiles: Integer;
    procedure ScanPath(const APath: String);
    procedure ScanFolder(const Folder: String);
    procedure SyncProgress;
    procedure SyncDone;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TMainForm; const ARoots: TStrings);
    destructor Destroy; override;
  end;

  { TMainForm }

  TMainForm = class(TForm)
  private
    { ── Toolbar (flat TPanel at top) ── }
    FToolPanel     : TPanel;
    FBtnOpen       : TSpeedButton;
    FBtnSave       : TSpeedButton;
    FChkCachePreviews: TCheckBox;  // copy preview folder locally on next IDF load
    FBtnClearCaches: TSpeedButton;
    FBtnBgCache   : TSpeedButton;
    FBtnCacheManager: TSpeedButton;
    FBtnFirst      : TSpeedButton;
    FBtnPrev       : TSpeedButton;
    FBtnNext       : TSpeedButton;
    FBtnLast       : TSpeedButton;
    FLblPageJump   : TLabel;
    FSpinPageJump  : TSpinEdit;
    FLblStrips     : TLabel;
    FSpinStrips    : TSpinEdit;
    FLblZoom       : TLabel;
    FTrackZoom     : TTrackBar;
    FSpinZoom      : TSpinEdit;
    FBtnRotate     : TSpeedButton;  // toggles CW / CCW rotation
    FChkAutoStrips : TCheckBox;     // auto-calculate strips per row
    FChkMultiManip : TCheckBox;     // apply drag ops to all selected frames
    FTopSnapshotGrp: TGroupBox;
    FLblMetricFrames: TLabel;
    FLblMetricSelection: TLabel;
    FLblMetricRoll: TLabel;
    FLblMetricPreview: TLabel;

    { ── Menu bar ── }
    FMainMenu        : TMainMenu;
    FMenuMIStripEdges: TMenuItem;   // needs field for Checked access

    { ── Layout panels ── }
    FMainSplitter  : TSplitter;
    FLeftPanel     : TPanel;
    FRightPanel    : TPanel;

    { ── Strip view ── }
    FStripView     : TStripView;

    { ── Right panel: tabs ── }
    FPageCtrl      : TPageControl;
    FTabDetect     : TTabSheet;
    FTabFraming    : TTabSheet;
    FTabProcess    : TTabSheet;
    FTabFiles      : TTabSheet;

    { ── Detect tab ── }
    FDetectScopeGrp : TGroupBox;
    FRbDetectFull   : TRadioButton;
    FRbDetectRange  : TRadioButton;
    FEdtRangeFrom   : TSpinEdit;
    FEdtRangeTo     : TSpinEdit;
    FSpinMinW       : TSpinEdit;
    FSpinMinH       : TSpinEdit;
    FBtnDetectStart : TBitBtn;
    FBtnDetectStop  : TBitBtn;
    FBtnDetectUndo  : TBitBtn;
    FChkDetectLivePreview: TCheckBox;
    FProgressDetect : TProgressBar;
    FLblDetectStatus: TLabel;
    FChkDetectAreaEnable: TCheckBox;
    FSpinDetectIgnoreTop: TSpinEdit;
    FSpinDetectIgnoreBottom: TSpinEdit;
    FBtnDetectAreaReset: TBitBtn;

    { ── Framing tab ── }
    FBtnSelPage          : TBitBtn;
    FBtnSelAll           : TBitBtn;
    FBtnSelNone          : TBitBtn;
    FBtnDeleteSelected   : TBitBtn;
    FBtnDeleteAll        : TBitBtn;
    FTrackFrameFillOpacity: TTrackBar;
    FLblFrameFillOpacity : TLabel;
    FGrpMarkers          : TGroupBox;
    FBtnMarkFolder       : TBitBtn;
    FBtnSuggestMarkers   : TBitBtn;
    FBtnSuggestStart     : TBitBtn;
    FBtnSuggestEnd       : TBitBtn;
    FBtnClearSuggested   : TBitBtn;
    FBtnClearSelectedSuggested: TBitBtn;
    FBtnClearMarkers     : TBitBtn;
    FBtnClearMarkersStart: TBitBtn;
    FBtnClearMarkersEnd  : TBitBtn;
    FSpinSuggestClearEvery: TSpinEdit;
    FBtnClearSuggestStart: TBitBtn;
    FBtnClearSuggestEnd  : TBitBtn;
    FLblMarkerCount      : TLabel;
    FLblSuggestSensitivity: TLabel;
    FTrackSensitivity    : TTrackBar;
    FChkSuggestBeforeGap : TCheckBox;
    { Framing – size detection }
    FChkShowOversized    : TCheckBox;
    FTrackOversized      : TTrackBar;
    FLblOverPct          : TLabel;
    FChkShowUndersized   : TCheckBox;
    FTrackUndersized     : TTrackBar;
    FLblUnderPct         : TLabel;
    FBtnSelectBySize     : TBitBtn;
    FBtnJumpSmall        : TBitBtn;
    FBtnJumpBig          : TBitBtn;
    FBtnJumpRed          : TBitBtn;
    { Framing – select suggested / split }
    FBtnSelectSuggested  : TBitBtn;
    FSpinSplitN          : TSpinEdit;
    FChkSplitPreview     : TCheckBox;
    FChkSplitConfirmMulti: TCheckBox;
    FBtnSplitFrame       : TBitBtn;
    { Framing – overlap / merge }
    FBtnCombineAll       : TBitBtn;
    FBtnCombineSelected  : TBitBtn;
    FBtnMergeAdjacent    : TBitBtn;
    FSpinJoinGap         : TSpinEdit;
    FBtnJoinCloseSelected: TBitBtn;
    FBtnCloseSelectedGaps: TBitBtn;
    FSpinExpandTop       : TSpinEdit;
    FSpinExpandBottom    : TSpinEdit;
    FSpinExpandLeft      : TSpinEdit;
    FSpinExpandRight     : TSpinEdit;
    FBtnExpandSelected   : TBitBtn;

    { ── Framing tab – trim ── }
    FChkTrimEnable  : TCheckBox;
    FSpinTrimTop    : TSpinEdit;
    FSpinTrimBottom : TSpinEdit;
    FBtnApplyTrim   : TBitBtn;

    { ── Process tab ── }
    FChkPerFrame         : TCheckBox;
    FBtnClearOverride    : TBitBtn;
    FBtnClearSelectedOverride: TBitBtn;
    FRbRotM90            : TRadioButton;
    FRbRot0              : TRadioButton;
    FRbRot90             : TRadioButton;
    FRbRot180            : TRadioButton;
    FChkMirror           : TCheckBox;
    FChkNegative         : TCheckBox;
    FRbProcFull          : TRadioButton;
    FRbProcSelected      : TRadioButton;
    FTrackBrightness     : TTrackBar;
    FTrackContrast       : TTrackBar;
    FTrackGamma          : TTrackBar;
    FComboAdjustMethod   : TComboBox;
    FChkShadowLift       : TCheckBox;
    FChkHighlightRecovery: TCheckBox;
    FChkSCurveContrast   : TCheckBox;
    FChkDocumentRescue   : TCheckBox;
    FChkSoftContrast     : TCheckBox;
    FLblSelectedAdjustment: TLabel;
    FSpinContrast        : TSpinEdit;
    FSpinBrightness      : TSpinEdit;
    FSpinGamma           : TSpinEdit;
    FTrackSharpness      : TTrackBar;
    FSpinSharpness       : TSpinEdit;
    FComboSharpnessMode  : TComboBox;
    FBtnAutoAdjustSelected: TBitBtn;
    FChkAdjustPreview    : TCheckBox;
    FBtnApplyPreview     : TBitBtn;
    FSpinQuality         : TSpinEdit;
    FBtnExportStart      : TBitBtn;
    FBtnPrepareFolders   : TBitBtn;
    FBtnReExportFailed   : TBitBtn;
    FBtnExportPause      : TBitBtn;
    FBtnExportStop       : TBitBtn;
    FSpinExportCache     : TSpinEdit;
    FSpinExportLoadThreads: TSpinEdit;
    FSpinExportProcessThreads: TSpinEdit;
    FChkExportGrayscale : TCheckBox;
    FChkExportProgressive: TCheckBox;
    FComboExportEncoder : TComboBox;
    FChkExportFollowPage: TCheckBox;
    FChkExportBatchUI   : TCheckBox;
    FChkExportLocalTemp : TCheckBox;
    FChkPrecreateFolders: TCheckBox;
    FChkExportTiming    : TCheckBox;
    FProgressExport      : TProgressBar;
    FLblExportStatus     : TLabel;

    { ── Files tab ── }
    FEdtJobName          : TEdit;
    FEdtRollName         : TEdit;
    FEdtOutputDir        : TEdit;
    FBtnBrowseOut        : TBitBtn;
    FEdtPrefix           : TEdit;
    FSpinFileDigits      : TSpinEdit;
    FSpinStartNum        : TSpinEdit;
    FChkSepFolders       : TCheckBox;
    FChkReverseOrder     : TCheckBox;
    FChkSkipExisting     : TCheckBox;
    FChkAllowPreviewExport: TCheckBox;
    FComboExportNaming   : TComboBox;
    FMemoArchiveList     : TMemo;
    FLblExportPreview    : TLabel;

    { ── Status bar ── }
    FStatusBar     : TStatusBar;

    { ── State ── }
    FRollData       : TRollData;
    FFrames         : TFrameList;
    FFrameStats     : TFrameStats;  // cached stats for current frame list
    FUndoFrames     : array of TFrameList;
    FDetectBaseFrames: TFrameList;
    FDetectLiveFromStrip: Integer;
    FDirty          : Boolean;
    FCurrentIDFPath : String;       // full path of the loaded IDF file
    FCurrentProjectPath: String;    // current SLF project save target
    FUndoDetectFrames: TFrameList;  // one-step restore before last detection
    FDetectCancel   : Boolean;
    FDetectRunning  : Boolean;
    FExportCancel   : Boolean;
    FExportPaused   : Boolean;
    FExportRunning  : Boolean;
    FExportLock     : TRTLCriticalSection;
    FExportBuildLock: TRTLCriticalSection;
    FExportSaveLock : TRTLCriticalSection;
    FExportJobs     : array of TExportJob;
    FExportJobDone  : array of Boolean;
    FExportNextJob  : Integer;
    FExportNextCommit: Integer;
    FExportBatchStart: Integer;
    FExportBatchEnd  : Integer;
    FExportFollowOrderIdx: Integer;
    FExportActiveWorkers: Integer;
    FExportDoneCount: Integer;
    FExportedCount  : Integer;
    FExportSkippedCount: Integer;
    FExportFailedCount: Integer;
    FExportBuildMs    : Int64;
    FExportLoadMs     : Int64;
    FExportCropMs     : Int64;
    FExportAdjustMs   : Int64;
    FExportSaveMs     : Int64;
    FExportTotalMs    : Int64;
    FExportRunId      : Integer;
    FExportLastProgressTick: QWord;
    FExportLastDoneCount: Integer;
    FExportWatchdogTimer: TTimer;
    FExportTracePath : String;
    FExportLastTrace : String;
    FExportFailedFrames: array of Integer;
    FExportFailedErrors: array of String;
    FExportRetryFailedOnly: Boolean;
    FApplyingZoom   : Boolean;
    FAutoLayoutUpdating: Boolean;
    FUpdatingDetectRange: Boolean;
    FUpdatingAdjustments: Boolean;
    FUpdatingExportNaming: Boolean;
    FDraggingAdjustmentSlider: Boolean;
    FDraggingVisualSlider: Boolean;
    FPreviewForm    : TForm;
    FPreviewScroll  : TScrollBox;
    FPreviewImage   : TImage;
    FPreviewStatus  : TLabel;
    FPreviewFrameStep: TSpinEdit;
    FPreviewFullRes : TCheckBox;
    FPreviewOneToOne: TCheckBox;
    FPreviewTopMost : TCheckBox;
    FPreviewFrameIdx: Integer;
    FPreviewZoomPct : Integer;
    FPreviewKeepFullRes: Boolean;
    FPreviewKeepOneToOne: Boolean;
    FPreviewKeepTopMost: Boolean;
    FApplyingPreviewZoom: Boolean;
    FPreviewPanning : Boolean;
    FPreviewPanStartMouse: TPoint;
    FPreviewPanStartHorz : Integer;
    FPreviewPanStartVert : Integer;
    FBgCacheThread : TPreviewCacheThread;
    FBgCacheQueueMode: Boolean;
    FCacheQueueRunning: Boolean;
    FCacheQueueStopRequested: Boolean;
    FCacheQueueIndex: Integer;
    FCacheQueuePaths: TStringList;
    FCacheMgrForm: TForm;
    FCacheMemo: TMemo;
    FCacheList: TListBox;
    FCacheMgrStatus: TLabel;
    FBtnCacheMgrStart: TBitBtn;
    FBtnCacheMgrStop: TBitBtn;
    FBtnCacheMgrAddPaths: TBitBtn;
    FBtnCacheMgrAddFolder: TBitBtn;
    FBtnCacheMgrRemove: TBitBtn;
    FBtnCacheMgrRefresh: TBitBtn;
    FCacheScanThread: TCacheScanThread;

    { ── UI builders ── }
    procedure BuildMainMenu;
    procedure BuildToolPanel;
    procedure BuildLayout;
    procedure BuildStripView;
    procedure BuildRightPanel;
    procedure BuildDetectTab;
    procedure BuildFramingTab;
    procedure BuildProcessTab;
    procedure BuildFilesTab;
    procedure BuildStatusBar;

    { ── Helpers ── }
    function MakeLabel(AParent: TWinControl; const ACaption: String;
                       X, Y: Integer): TLabel;
    function MakeButton(AParent: TWinControl; const ACaption: String;
                        X, Y, W, H: Integer;
                        Handler: TNotifyEvent): TBitBtn;
    function MakeGroupBox(AParent: TWinControl; const ACaption: String;
                          X, Y, W, H: Integer): TGroupBox;
    function MakeTrack(AParent: TWinControl; X, Y, W: Integer;
                       Lo, Hi, Pos: Integer): TTrackBar;
    procedure ConfigureTabScrollBox(Scroll: TScrollBox);
    function AppTitlePrefix: String;
    procedure SetAppTitle(const Suffix: String = '');
    function WaitForExportCommitTurn(RunId, OrderIdx: Integer): Boolean;
    procedure FinishExportCommitTurn(RunId: Integer);
    procedure ExportWorkerJobDone(RunId, OrderIdx, FrameIdx: Integer;
      Outcome: TExportOutcome; const Err: String;
      BuildMs, LoadMs, CropMs, AdjustMs, SaveMs,
      TotalMs: Int64);
    procedure ExportWorkerDone(RunId: Integer);
    procedure StartThreadedExport;
    function BuildExportJobsForCurrentScope(out Err: String): Boolean;
    function PrecreateCurrentExportJobFolders(out PreparedCount: Integer;
      out Err: String): Boolean;
    function PrepareExportFoldersForCurrentScope(out PreparedCount: Integer;
      out Err: String): Boolean;
    procedure ClearExportFailures;
    procedure AddExportFailure(FrameIdx: Integer; const Err: String);
    function ExportFailureSummary: String;
    procedure OnExportWatchdog(Sender: TObject);
    procedure ExportTrace(RunId: Integer; WorkerTag: PtrUInt; OrderIdx,
      FrameIdx: Integer; const Stage, Detail: String);

    { ── Handlers ── }
    procedure OnOpen(Sender: TObject);
    procedure OpenIDFFile(const FileName: String);
    procedure OpenProjectFile(const FileName: String);
    procedure OnOpenIDF(Sender: TObject);
    procedure OnOpenQPF(Sender: TObject);
    procedure OnOpenSLF(Sender: TObject);
    procedure OnSave(Sender: TObject);
    procedure OnSaveAs(Sender: TObject);
    procedure OnSaveQPFAs(Sender: TObject);
    procedure OnFirst(Sender: TObject);
    procedure OnPrev(Sender: TObject);
    procedure OnNext(Sender: TObject);
    procedure OnLast(Sender: TObject);
    procedure OnStripsChanged(Sender: TObject);
    procedure OnZoomChanged(Sender: TObject);
    procedure OnCachePreviewsToggle(Sender: TObject);
    procedure OnClearPreviewCaches(Sender: TObject);
    procedure OnBackgroundCache(Sender: TObject);
    procedure OnCacheManager(Sender: TObject);
    procedure OnCacheMgrAddPaths(Sender: TObject);
    procedure OnCacheMgrAddFolder(Sender: TObject);
    procedure OnCacheMgrRemove(Sender: TObject);
    procedure OnCacheMgrStart(Sender: TObject);
    procedure OnCacheMgrStop(Sender: TObject);
    procedure OnCacheMgrRefresh(Sender: TObject);
    procedure OnCacheMgrClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure OnStripsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnZoomKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnPageJumpKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnTabScrollMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);

    procedure OnPageChanged(Sender: TObject);
    procedure OnSelectionChanged(Sender: TObject);
    procedure OnExportMarkChanged(Sender: TObject);
    procedure OnSelectFrameSection(Sender: TObject);
    procedure OnDeleteFrameSection(Sender: TObject);
    procedure OnFrameDblClick(Sender: TObject);
    procedure OnFrameChanged(Sender: TObject);   { fired after drag-resize/move }
    procedure OnFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);

    procedure OnSelectPage(Sender: TObject);
    procedure OnSelectAll(Sender: TObject);
    procedure OnSelectNone(Sender: TObject);
    procedure OnDeleteSelected(Sender: TObject);
    procedure OnDeleteAll(Sender: TObject);
    procedure OnFrameFillOpacityChanged(Sender: TObject);
    procedure OnMarkFolder(Sender: TObject);
    procedure OnSuggestMarkers(Sender: TObject);
    procedure OnToggleSelectedSuggested(Sender: TObject);
    procedure OnSuggestSensitivityChanged(Sender: TObject);
    procedure OnClearSuggested(Sender: TObject);
    procedure OnClearSelectedSuggested(Sender: TObject);
    procedure OnClearSuggestedEvery(Sender: TObject);
    procedure OnClearMarkers(Sender: TObject);
    procedure OnClearMarkersDirection(Sender: TObject);

    procedure OnRotateToggle(Sender: TObject);
    procedure OnAutoStripsToggle(Sender: TObject);
    procedure OnMultiManipToggle(Sender: TObject);
    procedure OnLeftPanelResize(Sender: TObject);
    { Menu handlers }
    procedure OnSaveQPF(Sender: TObject);
    procedure OnExitApp(Sender: TObject);
    procedure OnViewStripEdges(Sender: TObject);
    procedure OnGoTo(Sender: TObject);
    procedure OnSettings(Sender: TObject);
    procedure OnAbout(Sender: TObject);
    procedure OnDetectStart(Sender: TObject);
    procedure OnDetectStop(Sender: TObject);
    procedure OnDetectUndo(Sender: TObject);
    procedure OnDetectAreaChanged(Sender: TObject);
    procedure OnDetectAreaReset(Sender: TObject);
    procedure OnDetectRangeControlChanged(Sender: TObject);
    procedure OnDetectRangeViewChanged(Sender: TObject);
    procedure OnBrowseOutput(Sender: TObject);
    procedure OnExportNamingChanged(Sender: TObject);
    procedure OnArchiveListChanged(Sender: TObject);
    procedure OnBuildArchiveListFromFolders(Sender: TObject);
    procedure OnExportStart(Sender: TObject);
    procedure OnPrepareExportFolders(Sender: TObject);
    procedure OnReExportFailed(Sender: TObject);
    procedure OnExportPause(Sender: TObject);
    procedure OnExportStop(Sender: TObject);
    { Process tab handlers }
    procedure OnPerFrameToggle(Sender: TObject);
    procedure OnClearPerFrameOverrides(Sender: TObject);
    procedure OnClearSelectedPerFrameOverrides(Sender: TObject);
    procedure OnRotationChanged(Sender: TObject);
    procedure OnScanDefaults(Sender: TObject);
    procedure OnAdjustmentSliderChanged(Sender: TObject);
    procedure OnAdjustmentSliderMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure OnAdjustmentSliderRelease(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure OnAdjustmentSliderKeyUp(Sender: TObject; var Key: Word;
      Shift: TShiftState);
    procedure OnAdjustmentSpinChanged(Sender: TObject);
    procedure OnAdjustmentMethodChanged(Sender: TObject);
    procedure OnAdjustmentOptionChanged(Sender: TObject);
    procedure OnPreviewAdjustmentChanged(Sender: TObject);
    procedure OnAdjustPreviewToggle(Sender: TObject);
    procedure OnSharpnessChanged(Sender: TObject);
    procedure OnSharpnessModeChanged(Sender: TObject);
    procedure OnAutoAdjustSelected(Sender: TObject);
    procedure OnVisualSliderMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure OnVisualSliderRelease(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    { Framing tab – size detection }
    procedure OnDetectSizeChanged(Sender: TObject);
    procedure OnSelectBySize(Sender: TObject);
    procedure OnJumpAttentionFrame(Sender: TObject);
    { Framing tab – suggested markers }
    procedure OnSelectSuggested(Sender: TObject);
    { Framing tab – split frame }
    procedure OnSplitPreviewChanged(Sender: TObject);
    procedure OnSplitFrame(Sender: TObject);
    { Framing tab – overlap / merge }
    procedure OnCombineOverlapping(Sender: TObject);
    procedure OnCombineSelectedOverlapping(Sender: TObject);
    procedure OnMergeAdjacent(Sender: TObject);
    procedure OnJoinCloseSelected(Sender: TObject);
    procedure OnCloseSelectedGaps(Sender: TObject);
    procedure OnExpandSelected(Sender: TObject);

    { Framing tab – trim }
    procedure OnTrimToggle(Sender: TObject);
    procedure OnTrimSpinChanged(Sender: TObject);
    procedure OnApplyTrim(Sender: TObject);
    procedure OnTrimViewChanged(Sender: TObject);   { from FStripView.OnTrimChanged }

    procedure DoAutoStrips;
    procedure MarkDirty;
    procedure PushFrameUndo;
    procedure ClearFrameUndo;
    procedure UndoLastFrameChange;
    procedure JumpToMarker(Forward: Boolean);
    function  PreviewCacheRoot: String;
    function  PreviewCacheProjectName: String;
    function  PreviewCacheProjectRoot: String;
    function  PreviewCacheProjectNameForIDF(const IDFPath: String): String;
    function  PreviewCacheProjectRootForIDF(const IDFPath: String): String;
    function  CacheQueueFile: String;
    function  CacheQueueStatusForProject(const ProjectPath: String;
                                         DeepCheck: Boolean): String;
    procedure LoadCacheQueue;
    procedure SaveCacheQueue;
    procedure RefreshCacheQueueList(DeepCheck: Boolean = False);
    procedure AddCacheQueuePath(const Path: String);
    procedure AddCacheQueueFolder(const Folder: String);
    procedure StartNextCacheQueueItem;
    procedure PurgeAllPreviewCaches;
    procedure PreparePreviewCacheForRoll;
    procedure BackgroundCacheProgress(Copied, Skipped, Missing, Current, Total: Integer;
                                      const Status: String);
    procedure BackgroundCacheDone(Copied, Skipped, Missing, Total: Integer;
                                  Cancelled: Boolean);
    procedure CacheScanProgress(ScannedFolders, ScannedFiles, FoundCount: Integer;
                                const Current: String);
    procedure CacheScanDone(Found: TStrings; ScannedFolders, ScannedFiles: Integer;
                            Cancelled: Boolean);
    procedure StopCacheScan(WaitForFinish: Boolean);
    procedure StopBackgroundCache(WaitForFinish: Boolean);
    function  SaveSLFToFile(const FileName: String; UpdateCurrentProject: Boolean): Boolean;
    function  SaveQPFToFile(const FileName: String): Boolean;
    function  PromptSaveSLFAs: Boolean;
    function  PromptSaveQPFAs: Boolean;
    procedure LoadProjectFile(const ProjectPath: String);
    function  ResolvePreviewPathForDetection(StripIndex: Integer; out Path: String;
                                             out CachedNow: Boolean): Boolean;
    procedure ApplyZoomPercent(Value: Integer);
    procedure SyncDetectRangeToView;
    procedure DeleteSelectedFrames(AskConfirm: Boolean);
    procedure SelectMarkerFrameSection(FrameIdx: Integer);
    procedure ReplaceFramesInStripRange(const DetectedFrames: TFrameList;
                                        FromStrip, ToStrip: Integer);
    function  OnDetectProgress(CurrentStrip, TotalStrips: Integer;
                               const Stats: TDetectStats;
                               const Frames: TFrameList): Boolean;
    procedure ReloadFramesKeepPage;
    procedure RefreshFrameColors;
    procedure DeleteFrameAt(Idx: Integer);
    function  GetSingleSelectedFrameIdx: Integer;
    function  EstimateAutoAdjustmentForFrame(FrameIdx: Integer; out Contrast,
      Brightness, Gamma: Integer): Boolean;
    procedure AutoAdjustSelectedFrames;
    function  CurrentProcessRotation: Integer;
    function  CurrentAdjustmentFlags: Integer;
    function  ProjectFramesFolder: String;
    function  ArchiveListLineIndexForFrame(FrameIdx: Integer): Integer;
    procedure HighlightArchiveListLineForFrame(FrameIdx: Integer);
    function  ExportPathForFrame(FrameIdx: Integer; out FolderPath, FileName,
                                 FullPath, Err: String): Boolean;
    function  ExportNamingPreviewForFrame(FrameIdx: Integer;
                                          IncludeOutputRoot: Boolean): String;
    procedure DeleteMarkerFrameSection(FrameIdx: Integer);
    procedure StoreAdjustmentControlsToRoll;
    procedure StoreExportNamingControlsToRoll;
    procedure LoadExportNamingControlsFromRoll;
    procedure LoadAdjustmentControlsFromRoll;
    procedure ApplyAdjustmentControlsToSelectedFrames;
    procedure UpdateSelectedAdjustmentStatus;
    procedure SetProcessRotation(Rot: Integer);
    procedure ShowFramePreview(FrameIdx: Integer);
    procedure RenderFramePreview;
    procedure PreviewSelectFrame(FrameIdx: Integer);
    procedure ApplyPreviewZoom;
    procedure FitPreviewZoom;
    procedure PreviewJumpMarker(Forward: Boolean);
    procedure PreviewApplyRotation(Delta: Integer);
    procedure PreviewToggleMirror;
    procedure PreviewToggleNegative;
    procedure OnPreviewWindowKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure OnPreviewFormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure OnPreviewNavButton(Sender: TObject);
    procedure OnPreviewProcessButton(Sender: TObject);
    procedure OnPreviewQualityToggle(Sender: TObject);
    procedure OnPreviewTopMostToggle(Sender: TObject);
    procedure OnPreviewMouseWheel(Sender: TObject; Shift: TShiftState;
      WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
    procedure OnPreviewMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure OnPreviewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure OnPreviewMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure OnPreviewScrollResize(Sender: TObject);
    procedure UpdateNavButtons;
    procedure UpdateTopSnapshot;
    procedure UpdateStatus;
    procedure UpdateFilesTab;

  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}
{ SelectDirectory is in Dialogs (already in interface uses) — no extra unit needed }

const
  ADJ_FLAG_SHADOW_LIFT = 1;
  ADJ_FLAG_HIGHLIGHT_RECOVERY = 2;
  ADJ_FLAG_S_CURVE = 4;
  ADJ_FLAG_DOCUMENT_RESCUE = 8;
  ADJ_FLAG_SOFT_CONTRAST = 16;
  EXPORT_JOB_BATCH_SIZE = 8;
  EXPORT_UI_FLUSH_INTERVAL = 32;
  EXPORT_FOLDER_CREATE_RETRIES = 3;
  EXPORT_FOLDER_CREATE_RETRY_MS = 200;

function NaturalTextCompare(const A, B: String): Integer;
var
  IA, IB, StartA, StartB, SigA, SigB, EndA, EndB, LenA, LenB, I: Integer;
  CA, CB: Char;
begin
  IA := 1;
  IB := 1;
  while (IA <= Length(A)) and (IB <= Length(B)) do
  begin
    CA := UpCase(A[IA]);
    CB := UpCase(B[IB]);
    if (CA in ['0'..'9']) and (CB in ['0'..'9']) then
    begin
      StartA := IA;
      StartB := IB;
      while (IA <= Length(A)) and (A[IA] in ['0'..'9']) do Inc(IA);
      while (IB <= Length(B)) and (B[IB] in ['0'..'9']) do Inc(IB);
      EndA := IA - 1;
      EndB := IB - 1;
      SigA := StartA;
      SigB := StartB;
      while (SigA < EndA) and (A[SigA] = '0') do Inc(SigA);
      while (SigB < EndB) and (B[SigB] = '0') do Inc(SigB);
      LenA := EndA - SigA + 1;
      LenB := EndB - SigB + 1;
      if LenA <> LenB then Exit(LenA - LenB);
      for I := 0 to LenA - 1 do
        if A[SigA + I] <> B[SigB + I] then
          Exit(Ord(A[SigA + I]) - Ord(B[SigB + I]));
      { Same numeric value: put the shorter spelling first (2 before 002). }
      if (EndA - StartA) <> (EndB - StartB) then
        Exit((EndA - StartA) - (EndB - StartB));
    end
    else
    begin
      if CA <> CB then Exit(Ord(CA) - Ord(CB));
      Inc(IA);
      Inc(IB);
    end;
  end;
  Result := (Length(A) - IA) - (Length(B) - IB);
end;

function NaturalStringListCompare(List: TStringList; Index1, Index2: Integer): Integer;
begin
  Result := NaturalTextCompare(List[Index1], List[Index2]);
end;

function ClampByteValue(Value: Integer): Byte;
begin
  if Value < 0 then Result := 0
  else if Value > 255 then Result := 255
  else Result := Value;
end;

procedure ApplySharpnessFilter(ABitmap: TBGRABitmap; Mode, Amount: Integer);
var
  Src: TBGRABitmap;
  X, Y, DX, DY: Integer;
  Strength, BlurR, BlurG, BlurB: Double;
  Center, Sample: PBGRAPixel;
  SrcRow, DstRow: PBGRAPixel;

  function PixelAt(AX, AY: Integer): PBGRAPixel;
  begin
    Result := Src.ScanLine[AY];
    Inc(Result, AX);
  end;

begin
  if (ABitmap = nil) or (ABitmap.Width < 3) or (ABitmap.Height < 3) then Exit;
  Amount := Max(0, Min(100, Amount));
  if Amount <= 0 then Exit;

  case Mode of
    1: Strength := 0.45 + Amount / 70.0;   // unsharp
    2: Strength := 0.65 + Amount / 48.0;   // text crisp
    3: Strength := 0.90 + Amount / 36.0;   // high-pass strong
  else
    Strength := 0.25 + Amount / 120.0;     // soft
  end;

  Src := ABitmap.GetPart(Rect(0, 0, ABitmap.Width, ABitmap.Height));
  try
    for Y := 1 to ABitmap.Height - 2 do
    begin
      DstRow := ABitmap.ScanLine[Y];
      Inc(DstRow);
      for X := 1 to ABitmap.Width - 2 do
      begin
        Center := PixelAt(X, Y);
        BlurR := 0;
        BlurG := 0;
        BlurB := 0;
        for DY := -1 to 1 do
          for DX := -1 to 1 do
          begin
            Sample := PixelAt(X + DX, Y + DY);
            BlurR := BlurR + Sample^.red;
            BlurG := BlurG + Sample^.green;
            BlurB := BlurB + Sample^.blue;
          end;
        BlurR := BlurR / 9.0;
        BlurG := BlurG / 9.0;
        BlurB := BlurB / 9.0;
        DstRow^.red := ClampByteValue(Round(Center^.red + (Center^.red - BlurR) * Strength));
        DstRow^.green := ClampByteValue(Round(Center^.green + (Center^.green - BlurG) * Strength));
        DstRow^.blue := ClampByteValue(Round(Center^.blue + (Center^.blue - BlurB) * Strength));
        DstRow^.alpha := Center^.alpha;
        Inc(DstRow);
      end;
    end;

    SrcRow := Src.ScanLine[0];
    DstRow := ABitmap.ScanLine[0];
    for X := 0 to ABitmap.Width - 1 do
    begin
      DstRow^ := SrcRow^;
      Inc(SrcRow);
      Inc(DstRow);
    end;
    SrcRow := Src.ScanLine[ABitmap.Height - 1];
    DstRow := ABitmap.ScanLine[ABitmap.Height - 1];
    for X := 0 to ABitmap.Width - 1 do
    begin
      DstRow^ := SrcRow^;
      Inc(SrcRow);
      Inc(DstRow);
    end;
  finally
    Src.Free;
  end;
end;

function ButtonCaptionWithIcon(const Cap: String): String;
begin
  Result := Cap;

  if Cap = '|<' then Result := ''
  else if Cap = '<' then Result := ''
  else if Cap = '>' then Result := ''
  else if Cap = '>|' then Result := ''
  else if Cap = 'Rot CCW' then Result := 'Rot'
  else if Cap = 'Start Cache' then Result := 'Cache'
  else if Cap = 'Delete Selected (D)' then Result := 'Delete Selected'
  else if Cap = 'Mark as Folder Start (A)' then Result := 'Mark Folder Start'
  else if Cap = 'Combine Selected Overlapping (J)' then Result := 'Combine Selected'
  else if Cap = 'Merge Adjacent Selected (Pairs) (E)' then Result := 'Merge Adjacent'
  else if Cap = 'Split Selected Frames (S)' then Result := 'Split Selected'
  else if Cap = 'Reset / Clear All Per-Frame Changes' then Result := 'Reset Per-Frame Changes'
  else if Cap = 'Clear Selected Per-Frame Changes' then Result := 'Clear Selected Changes'
  else if Cap = 'Clear toward Start' then Result := 'Clear Start'
  else if Cap = 'Clear toward End' then Result := 'Clear End'
  else if Cap = 'Select All Suggested' then Result := 'Select Suggested'
  else if Cap = 'Clear Selected Suggestions' then Result := 'Clear Selected'
  else if Cap = 'Clear All Suggestions' then Result := 'Clear Suggestions'
  else if Cap = '...' then Result := '';
end;

procedure DrawButtonGlyph(Bmp: TBitmap; const Cap: String);
var
  C: TCanvas;
  Accent, Dark, Paper, Warn, Green, Amber: TColor;
  Pts: array[0..2] of TPoint;

  procedure ClearGlyph;
  begin
    Bmp.SetSize(22, 22);
    Bmp.Transparent := True;
    Bmp.TransparentColor := clFuchsia;
    C := Bmp.Canvas;
    C.Brush.Color := clFuchsia;
    C.Brush.Style := bsSolid;
    C.FillRect(Rect(0, 0, Bmp.Width, Bmp.Height));
    C.Pen.Width := 2;
    C.Pen.Color := Dark;
    C.Brush.Color := Accent;
  end;

  procedure DrawPlay;
  begin
    C.Brush.Color := Accent;
    Pts[0] := Point(8, 5);
    Pts[1] := Point(8, 17);
    Pts[2] := Point(17, 11);
    C.Polygon(Pts);
  end;

  procedure DrawStop;
  begin
    C.Brush.Color := Warn;
    C.Rectangle(6, 6, 16, 16);
  end;

  procedure DrawFolder(CheckMark: Boolean);
  begin
    C.Brush.Color := Amber;
    C.Polygon([Point(3, 8), Point(8, 8), Point(10, 6), Point(19, 6), Point(19, 17), Point(3, 17)]);
    C.Rectangle(3, 9, 19, 17);
    if CheckMark then
    begin
      C.Pen.Color := Green;
      C.MoveTo(8, 13); C.LineTo(11, 16); C.LineTo(17, 9);
    end;
  end;

  procedure DrawX;
  begin
    C.Pen.Color := Warn;
    C.MoveTo(6, 6); C.LineTo(16, 16);
    C.MoveTo(16, 6); C.LineTo(6, 16);
  end;

  procedure DrawFrame(Selected: Boolean);
  begin
    if Selected then C.Pen.Color := Green else C.Pen.Color := Accent;
    C.Brush.Color := Paper;
    C.Rectangle(5, 6, 17, 16);
    C.Pen.Color := Dark;
    C.MoveTo(4, 4); C.LineTo(7, 4);
    C.MoveTo(15, 4); C.LineTo(18, 4);
    C.MoveTo(4, 18); C.LineTo(7, 18);
    C.MoveTo(15, 18); C.LineTo(18, 18);
  end;

  procedure DrawArrow(Dir: Integer);
  begin
    C.Brush.Color := Accent;
    if Dir < 0 then
    begin
      Pts[0] := Point(6, 11); Pts[1] := Point(15, 5); Pts[2] := Point(15, 17);
    end
    else
    begin
      Pts[0] := Point(16, 11); Pts[1] := Point(7, 5); Pts[2] := Point(7, 17);
    end;
    C.Polygon(Pts);
  end;

  procedure DrawArrowStop(Dir: Integer);
  begin
    DrawArrow(Dir);
    C.Pen.Color := Dark;
    if Dir < 0 then
    begin
      C.MoveTo(4, 5);
      C.LineTo(4, 17);
    end
    else
    begin
      C.MoveTo(19, 5);
      C.LineTo(19, 17);
    end;
  end;

  procedure DrawRefresh;
  begin
    C.Pen.Color := Accent;
    C.Brush.Style := bsClear;
    C.Arc(5, 5, 18, 18, 16, 7, 7, 16);
    C.Arc(5, 5, 18, 18, 6, 15, 16, 7);
    C.Brush.Style := bsSolid;
    C.Brush.Color := Accent;
    Pts[0] := Point(16, 5);
    Pts[1] := Point(19, 10);
    Pts[2] := Point(13, 9);
    C.Polygon(Pts);
  end;

  procedure DrawTrash;
  begin
    C.Pen.Color := Warn;
    C.Brush.Color := clFuchsia;
    C.Rectangle(7, 8, 16, 18);
    C.MoveTo(5, 7); C.LineTo(18, 7);
    C.MoveTo(9, 5); C.LineTo(14, 5);
    C.MoveTo(10, 10); C.LineTo(10, 16);
    C.MoveTo(13, 10); C.LineTo(13, 16);
  end;

  procedure DrawMarker;
  begin
    DrawFrame(False);
    C.Pen.Color := Amber;
    C.Brush.Color := Amber;
    C.MoveTo(6, 4); C.LineTo(6, 19);
    C.Polygon([Point(7, 5), Point(17, 7), Point(7, 10)]);
  end;

  procedure DrawWand;
  begin
    C.Pen.Color := Accent;
    C.MoveTo(6, 16); C.LineTo(16, 6);
    C.Pen.Color := Amber;
    C.MoveTo(5, 5); C.LineTo(5, 9);
    C.MoveTo(3, 7); C.LineTo(7, 7);
    C.MoveTo(17, 13); C.LineTo(17, 17);
    C.MoveTo(15, 15); C.LineTo(19, 15);
  end;

  procedure DrawCheck;
  begin
    C.Pen.Color := Green;
    C.MoveTo(5, 12); C.LineTo(9, 16); C.LineTo(17, 7);
  end;

  procedure DrawScissors;
  begin
    C.Pen.Color := Accent;
    C.Ellipse(4, 13, 9, 18);
    C.Ellipse(13, 13, 18, 18);
    C.MoveTo(8, 13); C.LineTo(17, 5);
    C.MoveTo(14, 13); C.LineTo(5, 5);
    C.Pen.Color := Amber;
    C.MoveTo(11, 3); C.LineTo(11, 19);
  end;

  procedure DrawMerge;
  begin
    C.Pen.Color := Accent;
    C.MoveTo(4, 8); C.LineTo(16, 8);
    C.MoveTo(13, 5); C.LineTo(16, 8); C.LineTo(13, 11);
    C.MoveTo(18, 14); C.LineTo(6, 14);
    C.MoveTo(9, 11); C.LineTo(6, 14); C.LineTo(9, 17);
    C.Pen.Color := Amber;
    C.MoveTo(11, 4); C.LineTo(11, 18);
  end;

  procedure DrawExport;
  begin
    C.Brush.Color := Paper;
    C.Pen.Color := Dark;
    C.Rectangle(5, 4, 14, 18);
    C.Pen.Color := Accent;
    C.MoveTo(11, 11); C.LineTo(19, 11);
    C.MoveTo(16, 8); C.LineTo(19, 11); C.LineTo(16, 14);
  end;

  procedure DrawPage;
  begin
    C.Brush.Color := Paper;
    C.Pen.Color := Dark;
    C.Rectangle(5, 3, 16, 19);
    C.MoveTo(12, 3); C.LineTo(16, 7); C.LineTo(12, 7); C.LineTo(12, 3);
    C.Pen.Color := Accent;
    C.MoveTo(8, 11); C.LineTo(18, 11);
    C.MoveTo(15, 8); C.LineTo(18, 11); C.LineTo(15, 14);
  end;

  procedure DrawStack(CheckIt: Boolean);
  begin
    C.Pen.Color := Accent;
    C.Brush.Color := Paper;
    C.Rectangle(3, 7, 10, 15);
    C.Rectangle(12, 7, 19, 15);
    C.Pen.Color := Dark;
    C.MoveTo(4, 5); C.LineTo(9, 5);
    C.MoveTo(13, 5); C.LineTo(18, 5);
    C.MoveTo(4, 17); C.LineTo(9, 17);
    C.MoveTo(13, 17); C.LineTo(18, 17);
    if CheckIt then
      DrawCheck;
  end;

  procedure DrawUnselect;
  begin
    DrawStack(False);
    C.Pen.Color := Accent;
    C.MoveTo(6, 18); C.LineTo(18, 6);
  end;

  procedure DrawFlaggedSize;
  begin
    DrawFrame(False);
    C.Pen.Color := Warn;
    C.MoveTo(4, 4); C.LineTo(18, 18);
    C.MoveTo(18, 4); C.LineTo(4, 18);
  end;

  procedure DrawFolderPrep;
  begin
    DrawFolder(False);
    C.Pen.Color := Green;
    C.MoveTo(11, 11); C.LineTo(11, 18);
    C.MoveTo(8, 15); C.LineTo(11, 18); C.LineTo(15, 13);
  end;

  procedure DrawRetryExport;
  begin
    DrawExport;
    C.Pen.Color := Green;
    C.Arc(9, 9, 21, 21, 18, 12, 13, 18);
  end;

  procedure DrawAdjust;
  begin
    C.Pen.Color := Accent;
    C.MoveTo(5, 6); C.LineTo(17, 6);
    C.MoveTo(5, 12); C.LineTo(17, 12);
    C.MoveTo(5, 18); C.LineTo(17, 18);
    C.Brush.Color := Green;
    C.Ellipse(8, 3, 12, 8);
    C.Brush.Color := Amber;
    C.Ellipse(13, 9, 17, 14);
    C.Brush.Color := Warn;
    C.Ellipse(6, 15, 10, 20);
  end;

  procedure DrawExpand;
  begin
    C.Pen.Color := Accent;
    C.Brush.Style := bsClear;
    C.Rectangle(8, 8, 16, 16);
    C.MoveTo(4, 4); C.LineTo(8, 8);
    C.MoveTo(4, 4); C.LineTo(4, 9);
    C.MoveTo(4, 4); C.LineTo(9, 4);
    C.MoveTo(20, 4); C.LineTo(16, 8);
    C.MoveTo(20, 4); C.LineTo(15, 4);
    C.MoveTo(20, 4); C.LineTo(20, 9);
    C.MoveTo(4, 20); C.LineTo(8, 16);
    C.MoveTo(4, 20); C.LineTo(4, 15);
    C.MoveTo(4, 20); C.LineTo(9, 20);
    C.MoveTo(20, 20); C.LineTo(16, 16);
    C.MoveTo(20, 20); C.LineTo(15, 20);
    C.MoveTo(20, 20); C.LineTo(20, 15);
    C.Brush.Style := bsSolid;
  end;

  procedure DrawCloseGap;
  begin
    C.Pen.Color := Accent;
    C.Brush.Style := bsClear;
    C.Rectangle(3, 7, 9, 17);
    C.Rectangle(15, 7, 21, 17);
    C.Brush.Style := bsSolid;
    C.Pen.Color := Green;
    C.MoveTo(4, 12); C.LineTo(12, 12);
    C.MoveTo(8, 9); C.LineTo(12, 12); C.LineTo(8, 15);
    C.MoveTo(20, 12); C.LineTo(12, 12);
    C.MoveTo(16, 9); C.LineTo(12, 12); C.LineTo(16, 15);
  end;

begin
  Accent := RGBToColor(33, 126, 238);
  Dark := RGBToColor(26, 43, 62);
  Paper := RGBToColor(239, 244, 249);
  Warn := RGBToColor(226, 73, 73);
  Green := RGBToColor(34, 190, 82);
  Amber := RGBToColor(244, 176, 48);
  ClearGlyph;

  if (Cap = 'Open...') or (Cap = 'Add Folder...') or (Cap = '...') then
    DrawFolder(Cap = '...')
  else if Cap = 'Prepare Folders' then
    DrawFolderPrep
  else if Cap = 'Save' then
  begin
    C.Brush.Color := Accent;
    C.Rectangle(4, 4, 18, 18);
    C.Brush.Color := Paper;
    C.Rectangle(7, 5, 15, 9);
    C.Rectangle(7, 13, 15, 18);
  end
  else if Cap = 'Stop Cache' then
    DrawStop
  else if (Pos('Cache', Cap) > 0) then
  begin
    C.Brush.Color := Paper;
    C.Ellipse(5, 4, 17, 10);
    C.Rectangle(5, 7, 17, 16);
    C.Ellipse(5, 12, 17, 19);
    C.Pen.Color := Accent;
    C.Ellipse(12, 11, 21, 20);
  end
  else if Cap = 'Select Page' then
    DrawPage
  else if Cap = 'Select All' then
    DrawStack(True)
  else if Cap = 'Select All Suggested' then
    DrawStack(True)
  else if Cap = 'Unselect All' then
    DrawUnselect
  else if Cap = 'Select Flagged Frames' then
    DrawFlaggedSize
  else if (Cap = 'Next Small') or (Cap = 'Next Big') or (Cap = 'Next Red') then
    DrawFlaggedSize
  else if Cap = 'Re-export Failed' then
    DrawRetryExport
  else if (Cap = 'Apply Preview') or (Cap = 'Apply Trim to All Frames') then
    DrawAdjust
  else if (Pos('Per-Frame', Cap) > 0) then
    DrawAdjust
  else if (Pos('Delete', Cap) > 0) or (Pos('Remove', Cap) > 0) then
    DrawTrash
  else if (Pos('Clear', Cap) > 0) then
    DrawX
  else if Pos('Mark', Cap) > 0 then
    DrawMarker
  else if (Pos('Suggest', Cap) > 0) or (Cap = 'Scan Defaults') then
    DrawWand
  else if (Pos('Split', Cap) > 0) then
    DrawScissors
  else if (Pos('Merge', Cap) > 0) or (Pos('Combine', Cap) > 0) then
    DrawMerge
  else if (Pos('Join Close', Cap) > 0) then
    DrawMerge
  else if (Pos('Close Gap', Cap) > 0) then
    DrawCloseGap
  else if (Pos('Expand', Cap) > 0) then
    DrawExpand
  else if (Pos('Export', Cap) > 0) or (Pos('Paths', Cap) > 0) then
    DrawExport
  else if (Pos('Rot', Cap) > 0) or (Pos('Refresh', Cap) > 0) or (Pos('Re-export', Cap) > 0) or
          (Pos('Reset', Cap) > 0) or (Pos('Undo', Cap) > 0) then
    DrawRefresh
  else if (Cap = 'Start Detection') then
    DrawFrame(True)
  else if (Pos('Select', Cap) > 0) then
  begin
    DrawFrame(True);
    DrawCheck;
  end
  else if (Cap = 'Stop') then
    DrawStop
  else if (Cap = '|<') then
    DrawArrowStop(-1)
  else if (Cap = '<') then
    DrawArrow(-1)
  else if (Cap = '>') then
    DrawArrow(1)
  else if (Cap = '>|') then
    DrawArrowStop(1)
  else if (Pos('Start', Cap) = 1) or (Cap = 'Start Queue') then
    DrawPlay
  else if (Cap = 'Pause') then
  begin
    C.Brush.Color := Accent;
    C.Rectangle(6, 5, 9, 17);
    C.Rectangle(13, 5, 16, 17);
  end
  else if (Cap = '<') or (Cap = '|<') or (Cap = 'Clear toward Start') then
    DrawArrow(-1)
  else if (Cap = '>') or (Cap = '>|') or (Cap = 'Clear toward End') then
    DrawArrow(1)
  else
    DrawFrame(False);
end;

procedure ApplyButtonGlyph(Btn: TBitBtn; const Cap: String);
var
  Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  try
    DrawButtonGlyph(Bmp, Cap);
    Btn.Glyph.Assign(Bmp);
    Btn.Layout := blGlyphLeft;
    Btn.Spacing := 6;
    Btn.Margin := 6;
  finally
    Bmp.Free;
  end;
end;

procedure ApplySpeedButtonGlyph(Btn: TSpeedButton; const Cap: String);
var
  Bmp: TBitmap;
begin
  Bmp := TBitmap.Create;
  try
    DrawButtonGlyph(Bmp, Cap);
    Btn.Glyph.Assign(Bmp);
    Btn.Layout := blGlyphLeft;
    Btn.Spacing := 4;
    Btn.Margin := 2;
  finally
    Bmp.Free;
  end;
end;

procedure ApplyButtonStyle(Btn: TBitBtn);
begin
  Btn.Font.Name := 'Segoe UI';
  Btn.Font.Size := 9;
end;

procedure ApplySpeedButtonStyle(Btn: TSpeedButton);
begin
  Btn.Font.Name := 'Segoe UI';
  Btn.Font.Size := 10;
  Btn.Font.Style := [fsBold];
end;

procedure SetSpeedButtonAction(Btn: TSpeedButton; const Cap: String);
begin
  if not Assigned(Btn) then Exit;
  Btn.Caption := ButtonCaptionWithIcon(Cap);
  ApplySpeedButtonGlyph(Btn, Cap);
end;

function EnsureDirectoryReady(const FolderPath: String; out Err: String): Boolean;
var
  Attempt: Integer;
begin
  Result := False;
  Err := '';
  if FolderPath = '' then
  begin
    Err := 'Output folder path is empty';
    Exit;
  end;

  for Attempt := 0 to EXPORT_FOLDER_CREATE_RETRIES do
  begin
    if DirectoryExists(FolderPath) then
    begin
      Result := True;
      Exit;
    end;

    try
      ForceDirectories(FolderPath);
    except
      on E: Exception do
        Err := E.Message;
    end;

    if DirectoryExists(FolderPath) then
    begin
      Result := True;
      Exit;
    end;

    if Attempt < EXPORT_FOLDER_CREATE_RETRIES then
      Sleep(EXPORT_FOLDER_CREATE_RETRY_MS);
  end;

  if Err = '' then
    Err := 'Could not create output folder: ' + FolderPath;
end;

{ ============================================================ }
{ Export worker thread                                         }
{ ============================================================ }

constructor TExportWorkerThread.Create(AOwner: TMainForm;
  const ASettings: TExportSettings);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := AOwner;
  FSettings := ASettings;
  FCache := TStringList.Create;
  FRunId := AOwner.FExportRunId;
  FBatchNext := 0;
  FBatchLast := -1;
  FDoneFrameIdx := -1;
  FDoneOrderIdx := -1;
  FDoneOutcome := eoFailed;
  FDoneLoadMs := 0;
  FDoneCropMs := 0;
  FDoneAdjustMs := 0;
end;

function TExportWorkerThread.ClaimNextJob(out Job: TExportJob): Boolean;
var
  i: Integer;
  BatchDone: Boolean;
begin
  Result := False;
  if not Assigned(FOwner) then Exit;

  while Assigned(FOwner) and (not Terminated) do
  begin
    EnterCriticalsection(FOwner.FExportLock);
    try
      if (FRunId <> FOwner.FExportRunId) or FOwner.FExportCancel then Exit;
      if FOwner.FExportNextJob > High(FOwner.FExportJobs) then Exit;

      if FOwner.FExportNextJob <= FOwner.FExportBatchEnd then
      begin
        Job := FOwner.FExportJobs[FOwner.FExportNextJob];
        Inc(FOwner.FExportNextJob);
        Exit(True);
      end;

      BatchDone := True;
      for i := FOwner.FExportBatchStart to FOwner.FExportBatchEnd do
        if (i >= 0) and (i <= High(FOwner.FExportJobDone)) and
           (not FOwner.FExportJobDone[i]) then
        begin
          BatchDone := False;
          Break;
        end;

      if BatchDone then
      begin
        FOwner.FExportBatchStart := FOwner.FExportNextJob;
        FOwner.FExportBatchEnd := Min(High(FOwner.FExportJobs),
          FOwner.FExportBatchStart + EXPORT_JOB_BATCH_SIZE - 1);
        Continue;
      end;
    finally
      LeaveCriticalsection(FOwner.FExportLock);
    end;
    Sleep(20);
  end;
end;

function TExportWorkerThread.IsBitmapResourceError(const Err: String): Boolean;
var
  LowerErr: String;
begin
  LowerErr := LowerCase(Err);
  Result := (Pos('windows error 8', LowerErr) > 0) or
            (Pos('reallocbitmap', LowerErr) > 0) or
            (Pos('out of memory', LowerErr) > 0) or
            (Pos('access violation', LowerErr) > 0);
end;

procedure TExportWorkerThread.TraceJob(const Stage: String;
  const Job: TExportJob; const Detail: String);
begin
  if Assigned(FOwner) then
    FOwner.ExportTrace(FRunId, PtrUInt(Self), Job.OrderIdx, Job.FrameIdx,
      Stage, Detail);
end;

destructor TExportWorkerThread.Destroy;
begin
  FreeSourceCache;
  inherited Destroy;
end;

function TExportWorkerThread.ClampInt(Value, Lo, Hi: Integer): Integer;
begin
  Result := Max(Lo, Min(Hi, Value));
end;

function TExportWorkerThread.CeilDiv64(Value, Divisor: Int64): Integer;
begin
  if Divisor <= 0 then Exit(1);
  if Value <= 0 then Exit(1);
  Result := Integer((Value + Divisor - 1) div Divisor);
  if Result < 1 then Result := 1;
end;

function TExportWorkerThread.FrameStripFilesAvailable(const F: TFrameRecord;
  FirstStrip, LastStrip: Integer): Boolean;
var
  S: Integer;
begin
  Result := True;
  for S := FirstStrip to LastStrip do
    if not FileExists(StripFilePath(FSettings.Roll, S)) then
      Exit(False);
end;

procedure TExportWorkerThread.FreeSourceCache;
begin
  if not Assigned(FCache) then Exit;
  ClearSourceCache;
  FreeAndNil(FCache);
end;

procedure TExportWorkerThread.ClearSourceCache;
var
  i: Integer;
begin
  if not Assigned(FCache) then
  begin
    FCache := TStringList.Create;
    Exit;
  end;
  for i := 0 to FCache.Count - 1 do
    FCache.Objects[i].Free;
  FCache.Clear;
end;

function TExportWorkerThread.CachedRawSource(const SourcePath: String;
  out Err: String): TBGRABitmap;
var
  CacheIdx: Integer;
  RawBmp: TBGRABitmap;
  Ext, LoadErr: String;
begin
  Result := nil;
  Err := '';
  CacheIdx := FCache.IndexOf(SourcePath);
  if CacheIdx >= 0 then
    Exit(TBGRABitmap(FCache.Objects[CacheIdx]));

  RawBmp := nil;
  try
    Ext := LowerCase(ExtractFileExt(SourcePath));
    if (FSettings.JpgEncoder = EXPORT_ENCODER_TURBOJPEG) and
       ((Ext = '.jpg') or (Ext = '.jpeg')) then
    begin
      LoadErr := '';
      if not LoadTurboJPEG(SourcePath, RawBmp, LoadErr) then
        RawBmp := nil;
    end;
    if not Assigned(RawBmp) then
      RawBmp := TBGRABitmap.Create(SourcePath);

    while FCache.Count >= FSettings.CacheLimit do
    begin
      FCache.Objects[0].Free;
      FCache.Delete(0);
    end;
    FCache.AddObject(SourcePath, RawBmp);
    Result := RawBmp;
    RawBmp := nil;
  except
    on E: Exception do
      Err := E.Message;
  end;
  RawBmp.Free;
end;

procedure TExportWorkerThread.ResolveFrameProcessing(const F: TFrameRecord;
  out Rot: Integer; out FlipH, FlipV, Negative: Boolean; out Method, Flags,
  Contrast, Brightness, Gamma: Integer);
begin
  if F.HasOverride then
  begin
    Rot := F.Rotation;
    FlipH := F.FlipH;
    FlipV := F.FlipV;
    Negative := F.Negative;
  end
  else
  begin
    Rot := FSettings.GlobalRotation;
    FlipH := FSettings.GlobalFlipH;
    FlipV := FSettings.GlobalFlipV;
    Negative := FSettings.GlobalNegative;
  end;
  Rot := ((Rot mod 360) + 360) mod 360;
  if (Rot <> 0) and (Rot <> 90) and (Rot <> 180) and (Rot <> 270) then
    Rot := 0;

  Method := FSettings.GlobalMethod;
  Flags := FSettings.GlobalFlags;
  Contrast := FSettings.GlobalContrast;
  Brightness := FSettings.GlobalBrightness;
  Gamma := FSettings.GlobalGamma;
  if (F.PerFrameContrast <> -1) or (F.PerFrameBrightness <> -1) or
     (F.PerFrameGamma <> -1) then
  begin
    Method := 1;
    Flags := 0;
    Contrast := 64;
    Brightness := 0;
    Gamma := 0;
    if F.PerFrameContrast <> -1 then Contrast := F.PerFrameContrast;
    if F.PerFrameBrightness <> -1 then Brightness := F.PerFrameBrightness;
    if F.PerFrameGamma <> -1 then Gamma := F.PerFrameGamma;
  end
  else
  begin
    if F.CustomContrast <> -1 then Contrast := F.CustomContrast;
    if F.CustomBrightness <> -1 then Brightness := F.CustomBrightness;
    if F.CustomGamma <> -1 then Gamma := F.CustomGamma;
  end;
end;

procedure TExportWorkerThread.ApplyNegative(ABitmap: TBGRABitmap);
var
  X, Y: Integer;
  P: PBGRAPixel;
begin
  for Y := 0 to ABitmap.Height - 1 do
  begin
    P := ABitmap.ScanLine[Y];
    for X := 0 to ABitmap.Width - 1 do
    begin
      P^.red := 255 - P^.red;
      P^.green := 255 - P^.green;
      P^.blue := 255 - P^.blue;
      Inc(P);
    end;
  end;
end;

procedure TExportWorkerThread.ApplyGrayAdjustment(ABitmap: TBGRABitmap; Method,
  Flags, Contrast, Brightness, Gamma: Integer);
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
  X, Y: Integer;
  LUT: array[0..255] of Byte;
  P: PBGRAPixel;

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
  for Y := 0 to ABitmap.Height - 1 do
  begin
    P := ABitmap.ScanLine[Y];
    for X := 0 to ABitmap.Width - 1 do
    begin
      P^.red := LUT[P^.red];
      P^.green := LUT[P^.green];
      P^.blue := LUT[P^.blue];
      Inc(P);
    end;
  end;
end;

function TExportWorkerThread.AdjustmentIsNoOp(Method, Flags, Contrast,
  Brightness, Gamma: Integer): Boolean;
begin
  if Flags <> 0 then Exit(False);
  case Method of
    1, 4:
      Result := (Contrast = 64) and (Brightness = 0) and (Gamma = 0);
    2, 3:
      Result := False;
  else
    Result := (Contrast = 0) and (Brightness = 0) and (Gamma = 100);
  end;
end;

function TExportWorkerThread.BuildFrameBitmap(FrameIdx: Integer;
  out ABitmap: TBGRABitmap; out Err: String; out LoadMs, CropMs,
  AdjustMs: Int64): Boolean;
var
  F: TFrameRecord;
  FirstStrip, LastStrip, StripIdx, DS: Integer;
  UseFullSource: Boolean;
  LocalLead, LocalTrail: Int64;
  SrcLeft, SrcRight, SrcTop, SrcBottom: Integer;
  SourceW, SourceH, TotalW, MaxH, OffsetX: Integer;
  SourcePath: String;
  Source, CropBmp, SegmentBmp, ProcessedBmp, TempBmp: TBGRABitmap;
  SegmentRects: array of TRect;
  Rot, Method, Flags, Contrast, Brightness, Gamma: Integer;
  FlipH, FlipV, Negative: Boolean;
  StageStart: QWord;
begin
  Result := False;
  ABitmap := nil;
  Err := '';
  LoadMs := 0;
  CropMs := 0;
  AdjustMs := 0;
  F := FSettings.Frames[FrameIdx];
  DS := Max(1, FSettings.Roll.PreviewDownScale);
  FirstStrip := Max(0, FrameLeadStrip(F, FSettings.Roll.LengthLines));
  LastStrip := Min(FSettings.Roll.StripCount - 1,
    FrameTrailStrip(F, FSettings.Roll.LengthLines));
  if LastStrip < FirstStrip then LastStrip := FirstStrip;
  UseFullSource := FrameStripFilesAvailable(F, FirstStrip, LastStrip);
  if (not UseFullSource) and (not FSettings.AllowPreviewFallback) then
  begin
    Err := 'Missing full strip source for frame; preview fallback is disabled.';
    Exit;
  end;

  SetLength(SegmentRects, LastStrip - FirstStrip + 1);
  TotalW := 0;
  MaxH := 0;
  for StripIdx := FirstStrip to LastStrip do
  begin
    LocalLead := F.LeadEdge - Int64(StripIdx) * FSettings.Roll.LengthLines;
    LocalTrail := F.TrailEdge - Int64(StripIdx) * FSettings.Roll.LengthLines;
    if LocalLead < 0 then LocalLead := 0;
    if LocalTrail > FSettings.Roll.LengthLines then
      LocalTrail := FSettings.Roll.LengthLines;
    if LocalTrail <= LocalLead then Continue;

    if UseFullSource then
    begin
      SourceW := Max(1, FSettings.Roll.WidthPixels);
      SourceH := Max(1, FSettings.Roll.LengthLines);
      SrcLeft := ClampInt(LocalLead, 0, SourceH - 1);
      SrcRight := ClampInt(LocalTrail, SrcLeft + 1, SourceH);
      SrcTop := ClampInt(F.LeftEdge, 0, SourceW - 1);
      SrcBottom := ClampInt(F.RightEdge, SrcTop + 1, SourceW);
    end
    else
    begin
      SourceW := CeilDiv64(FSettings.Roll.WidthPixels, DS);
      SourceH := CeilDiv64(FSettings.Roll.LengthLines, DS);
      SrcLeft := ClampInt(LocalLead div DS, 0, SourceH - 1);
      SrcRight := ClampInt((LocalTrail + DS - 1) div DS, SrcLeft + 1, SourceH);
      SrcTop := ClampInt(F.LeftEdge div DS, 0, SourceW - 1);
      SrcBottom := ClampInt((F.RightEdge + DS - 1) div DS, SrcTop + 1, SourceW);
    end;
    SegmentRects[StripIdx - FirstStrip] := Rect(SrcLeft, SrcTop, SrcRight, SrcBottom);
    Inc(TotalW, SrcRight - SrcLeft);
    MaxH := Max(MaxH, SrcBottom - SrcTop);
  end;

  if (TotalW <= 0) or (MaxH <= 0) then
  begin
    Err := 'Frame has no visible image area.';
    Exit;
  end;

  ABitmap := TBGRABitmap.Create(TotalW, MaxH, BGRA(0, 0, 0));
  try
    OffsetX := 0;
    for StripIdx := FirstStrip to LastStrip do
    begin
      SrcLeft := SegmentRects[StripIdx - FirstStrip].Left;
      SrcTop := SegmentRects[StripIdx - FirstStrip].Top;
      SrcRight := SegmentRects[StripIdx - FirstStrip].Right;
      SrcBottom := SegmentRects[StripIdx - FirstStrip].Bottom;
      if (SrcRight <= SrcLeft) or (SrcBottom <= SrcTop) then Continue;

      if UseFullSource then
        SourcePath := StripFilePath(FSettings.Roll, StripIdx)
      else
        SourcePath := PreviewFilePath(FSettings.Roll, StripIdx);
      if not FileExists(SourcePath) then
      begin
        Err := 'Missing source image: ' + SourcePath;
        Exit;
      end;

      StageStart := GetTickCount64;
      Source := CachedRawSource(SourcePath, Err);
      Inc(LoadMs, GetTickCount64 - StageStart);
      if not Assigned(Source) then Exit;
      CropBmp := nil;
      SegmentBmp := nil;
      try
        StageStart := GetTickCount64;
        SrcTop := ClampInt(SrcTop, 0, Source.Width - 1);
        SrcBottom := ClampInt(SrcBottom, SrcTop + 1, Source.Width);
        SrcLeft := ClampInt(SrcLeft, 0, Source.Height - 1);
        SrcRight := ClampInt(SrcRight, SrcLeft + 1, Source.Height);
        CropBmp := Source.GetPart(Rect(SrcTop, SrcLeft, SrcBottom, SrcRight));
        if FSettings.SourceRotateCW then
        begin
          SegmentBmp := CropBmp.RotateCW;
          SegmentBmp.HorizontalFlip;
        end
        else
          SegmentBmp := CropBmp.RotateCCW;
        FreeAndNil(CropBmp);
        ABitmap.PutImage(OffsetX, 0, SegmentBmp, dmSet);
        Inc(CropMs, GetTickCount64 - StageStart);
        Inc(OffsetX, SegmentBmp.Width);
      finally
        SegmentBmp.Free;
        CropBmp.Free;
      end;
    end;

    ResolveFrameProcessing(F, Rot, FlipH, FlipV, Negative, Method, Flags,
      Contrast, Brightness, Gamma);
    ProcessedBmp := nil;
    TempBmp := nil;
    try
      StageStart := GetTickCount64;
      case Rot of
        90: ProcessedBmp := ABitmap.RotateCW;
        180:
          begin
            TempBmp := ABitmap.RotateCW;
            ProcessedBmp := TempBmp.RotateCW;
          end;
        270: ProcessedBmp := ABitmap.RotateCCW;
      else
        ProcessedBmp := ABitmap.GetPart(Rect(0, 0, ABitmap.Width, ABitmap.Height));
      end;
      if FlipH then ProcessedBmp.HorizontalFlip;
      if FlipV then ProcessedBmp.VerticalFlip;
      if not AdjustmentIsNoOp(Method, Flags, Contrast, Brightness, Gamma) then
        ApplyGrayAdjustment(ProcessedBmp, Method, Flags, Contrast, Brightness, Gamma);
      if Negative then ApplyNegative(ProcessedBmp);
      ApplySharpnessFilter(ProcessedBmp, FSettings.GlobalSharpnessMode,
        FSettings.GlobalSharpness);
      FreeAndNil(ABitmap);
      ABitmap := ProcessedBmp;
      ProcessedBmp := nil;
      Inc(AdjustMs, GetTickCount64 - StageStart);
    finally
      TempBmp.Free;
      ProcessedBmp.Free;
    end;
    Result := True;
  except
    on E: Exception do
    begin
      Err := E.Message;
      FreeAndNil(ABitmap);
    end;
  end;
end;

procedure TExportWorkerThread.SaveJpeg(ABitmap: TBGRABitmap; const Path: String);
var
  Writer: TFPWriterJPEG;
  Err: String;
begin
  if FSettings.JpgEncoder = EXPORT_ENCODER_TURBOJPEG then
  begin
    if SaveTurboJPEG(ABitmap, Path, FSettings.JpgQuality,
      FSettings.JpgGrayscale, FSettings.JpgProgressive, Err) then
      Exit;
    raise Exception.Create(Err);
  end;

  Writer := TFPWriterJPEG.Create;
  try
    Writer.CompressionQuality := Max(1, Min(100, FSettings.JpgQuality));
    Writer.GrayScale := FSettings.JpgGrayscale;
    Writer.ProgressiveEncoding := FSettings.JpgProgressive;
    ABitmap.SaveToFile(Path, Writer);
  finally
    Writer.Free;
  end;
end;

procedure TExportWorkerThread.SaveJpegStaged(ABitmap: TBGRABitmap;
  const Path: String);
var
  TempDir, TempPath: String;
  InStream, OutStream: TFileStream;
begin
  if not FSettings.LocalTempStage then
  begin
    SaveJpeg(ABitmap, Path);
    Exit;
  end;

  TempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'Striplight_export_temp';
  ForceDirectories(TempDir);
  TempPath := IncludeTrailingPathDelimiter(TempDir) +
    'frame_' + IntToHex(PtrUInt(Self), 8) + '_' +
    IntToStr(GetTickCount64) + '.jpg';

  SaveJpeg(ABitmap, TempPath);
  try
    InStream := TFileStream.Create(TempPath, fmOpenRead or fmShareDenyNone);
    try
      OutStream := TFileStream.Create(Path, fmCreate);
      try
        OutStream.CopyFrom(InStream, 0);
      finally
        OutStream.Free;
      end;
    finally
      InStream.Free;
    end;
  finally
    DeleteFile(TempPath);
  end;
end;

procedure TExportWorkerThread.SyncJobDone;
begin
  if Assigned(FOwner) then
    FOwner.ExportWorkerJobDone(FRunId, FDoneOrderIdx, FDoneFrameIdx,
      FDoneOutcome, FDoneError, FDoneBuildMs, FDoneLoadMs, FDoneCropMs,
      FDoneAdjustMs, FDoneSaveMs, FDoneTotalMs);
end;

procedure TExportWorkerThread.SyncWorkerDone;
begin
  if Assigned(FOwner) then
    FOwner.ExportWorkerDone(FRunId);
end;

procedure TExportWorkerThread.Execute;
var
  Job: TExportJob;
  Bmp: TBGRABitmap;
  Err: String;
  BuildOk: Boolean;
  BuildAttempt: Integer;
  StartMs, BuildDoneMs, SaveStartMs, SaveDoneMs: QWord;
begin
  try
    while Assigned(FOwner) and (not Terminated) do
    begin
      while Assigned(FOwner) and FOwner.FExportPaused and
            (not FOwner.FExportCancel) and (not Terminated) do
        Sleep(75);
      if (not Assigned(FOwner)) or FOwner.FExportCancel or Terminated then Break;
      if not ClaimNextJob(Job) then Break;

      FDoneFrameIdx := Job.FrameIdx;
      FDoneOrderIdx := Job.OrderIdx;
      FDoneError := '';
      FDoneBuildMs := 0;
      FDoneLoadMs := 0;
      FDoneCropMs := 0;
      FDoneAdjustMs := 0;
      FDoneSaveMs := 0;
      FDoneTotalMs := 0;
      StartMs := GetTickCount64;
      Bmp := nil;
      try
        TraceJob('claim', Job, Job.FullPath);
        if FSettings.SkipExisting and FileExists(Job.FullPath) then
        begin
          FDoneOutcome := eoSkipped;
          TraceJob('skip-existing', Job, Job.FullPath);
        end
        else
        begin
          BuildOk := False;
          for BuildAttempt := 1 to 3 do
          begin
            TraceJob('build-start', Job, Format('attempt %d', [BuildAttempt]));
            Err := '';
            FreeAndNil(Bmp);
            if BuildAttempt = 1 then
              BuildOk := BuildFrameBitmap(Job.FrameIdx, Bmp, Err, FDoneLoadMs,
                FDoneCropMs, FDoneAdjustMs)
            else
            begin
              EnterCriticalsection(FOwner.FExportBuildLock);
              try
                BuildOk := BuildFrameBitmap(Job.FrameIdx, Bmp, Err,
                  FDoneLoadMs, FDoneCropMs, FDoneAdjustMs);
              finally
                LeaveCriticalsection(FOwner.FExportBuildLock);
              end;
            end;
            if BuildOk then Break;
            if not IsBitmapResourceError(Err) then Break;

            TraceJob('build-retry-resource', Job, Err);
            FreeAndNil(Bmp);
            ClearSourceCache;
            Sleep(1500 * BuildAttempt);
          end;

          if BuildOk then
            FDoneOutcome := eoExported
          else
          begin
            FDoneOutcome := eoFailed;
            FDoneError := Err;
          end;
        end;
        BuildDoneMs := GetTickCount64;
        FDoneBuildMs := BuildDoneMs - StartMs;
        if FDoneOutcome = eoFailed then
          TraceJob('build-failed', Job, FDoneError)
        else
          TraceJob('build-ok', Job, Format('%d ms', [FDoneBuildMs]));

        if FDoneOutcome = eoExported then
        begin
          try
            Err := '';
            if EnsureDirectoryReady(Job.FolderPath, Err) then
            begin
              TraceJob('save-start', Job, Job.FullPath);
              SaveStartMs := GetTickCount64;
              EnterCriticalsection(FOwner.FExportSaveLock);
              try
                SaveJpegStaged(Bmp, Job.FullPath);
              finally
                LeaveCriticalsection(FOwner.FExportSaveLock);
              end;
              SaveDoneMs := GetTickCount64;
              FDoneSaveMs := SaveDoneMs - SaveStartMs;
              TraceJob('save-ok', Job, Format('%d ms', [FDoneSaveMs]));
            end
            else
            begin
              FDoneOutcome := eoFailed;
              FDoneError := Err;
              TraceJob('save-failed', Job, FDoneError);
            end;
          except
            on E: Exception do
            begin
              FDoneOutcome := eoFailed;
              FDoneError := E.Message;
              TraceJob('save-failed', Job, FDoneError);
            end;
          end;
        end;
      except
        on E: Exception do
        begin
          FDoneOutcome := eoFailed;
          FDoneError := E.Message;
          TraceJob('job-exception', Job, FDoneError);
        end;
      end;

      try
        FDoneTotalMs := GetTickCount64 - StartMs;
        Synchronize(@SyncJobDone);
      finally
        Bmp.Free;
      end;
    end;
  finally
    Synchronize(@SyncWorkerDone);
  end;
end;

{ ============================================================ }
{ Construction                                                  }
{ ============================================================ }

constructor TPreviewCacheThread.Create(AOwner: TMainForm; const ARoll: TRollData);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FRoll := ARoll;
  FTotal := Max(0, FRoll.StripCount);
  FCopied := 0;
  FSkipped := 0;
  FMissing := 0;
  FCurrent := 0;
  FStatus := 'Starting background preview cache...';
  Start;
end;

function TPreviewCacheThread.ProjectLabel: String;
begin
  Result := ExtractFileName(FRoll.RollName);
  if Result = '' then
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(FRoll.BasePath));
  if Result = '' then
    Result := 'project';
end;

function TPreviewCacheThread.PreviewSourceFolderPath: String;
var
  SourceBase, SourceFolder: String;
begin
  SourceBase := FRoll.PreviewSourceBasePath;
  if SourceBase = '' then SourceBase := FRoll.BasePath;
  SourceFolder := FRoll.PreviewSourceFolder;
  if SourceFolder = '' then SourceFolder := FRoll.PreviewFolder;
  Result := IncludeTrailingPathDelimiter(SourceBase) + SourceFolder;
end;

function TPreviewCacheThread.PreviewSourcePath(StripIndex: Integer): String;
var
  SourceBase, SourceFolder: String;
begin
  SourceBase := FRoll.PreviewSourceBasePath;
  if SourceBase = '' then SourceBase := FRoll.BasePath;
  SourceFolder := FRoll.PreviewSourceFolder;
  if SourceFolder = '' then SourceFolder := FRoll.PreviewFolder;
  Result := IncludeTrailingPathDelimiter(SourceBase)
          + SourceFolder
          + PathDelim
          + FRoll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, FRoll.StripDigits)
          + '.jpg';
end;

function TPreviewCacheThread.PreviewCachePath(StripIndex: Integer): String;
begin
  Result := IncludeTrailingPathDelimiter(FRoll.PreviewBasePath)
          + FRoll.PreviewFolder
          + PathDelim
          + FRoll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, FRoll.StripDigits)
          + '.jpg';
end;

procedure TPreviewCacheThread.CopyOneFile(const SourceFile, DestFile: String);
var
  InStream, OutStream: TFileStream;
begin
  ForceDirectories(ExtractFilePath(DestFile));
  InStream := TFileStream.Create(SourceFile, fmOpenRead or fmShareDenyNone);
  try
    OutStream := TFileStream.Create(DestFile, fmCreate);
    try
      OutStream.CopyFrom(InStream, 0);
    finally
      OutStream.Free;
    end;
  finally
    InStream.Free;
  end;
end;

procedure TPreviewCacheThread.SyncProgress;
begin
  if Assigned(FOwner) then
    FOwner.BackgroundCacheProgress(FCopied, FSkipped, FMissing, FCurrent, FTotal, FStatus);
end;

procedure TPreviewCacheThread.SyncDone;
begin
  if Assigned(FOwner) then
    FOwner.BackgroundCacheDone(FCopied, FSkipped, FMissing, FTotal, Terminated);
end;

procedure TPreviewCacheThread.Execute;
var
  i: Integer;
  SourcePath, CachePath: String;
begin
  FStatus := Format('Caching %s   Folder: %s', [ProjectLabel, PreviewSourceFolderPath]);
  Synchronize(@SyncProgress);
  for i := 0 to FTotal - 1 do
  begin
    if Terminated then Break;
    FCurrent := i + 1;
    SourcePath := PreviewSourcePath(i);
    CachePath := PreviewCachePath(i);

    if FileExists(CachePath) then
      Inc(FSkipped)
    else if FileExists(SourcePath) then
    begin
      try
        CopyOneFile(SourcePath, CachePath);
        Inc(FCopied);
      except
        Inc(FMissing);
      end;
    end
    else
      Inc(FMissing);

    if (FCurrent = FTotal) or ((FCurrent mod 10) = 0) or
       ((FCopied > 0) and ((FCopied mod 25) = 0)) then
    begin
      FStatus := Format('Caching %s   %d / %d   Copied: %d   Already cached: %d   Missing: %d   Folder: %s',
        [ProjectLabel, FCurrent, FTotal, FCopied, FSkipped, FMissing, PreviewSourceFolderPath]);
      Synchronize(@SyncProgress);
    end;
  end;
  Synchronize(@SyncDone);
end;

constructor TCacheScanThread.Create(AOwner: TMainForm; const ARoots: TStrings);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
  FRoots := TStringList.Create;
  FRoots.Assign(ARoots);
  FFound := TStringList.Create;
  FFound.Sorted := True;
  FFound.Duplicates := dupIgnore;
  FCurrent := '';
  FScannedFolders := 0;
  FScannedFiles := 0;
  Start;
end;

destructor TCacheScanThread.Destroy;
begin
  FFound.Free;
  FRoots.Free;
  inherited Destroy;
end;

procedure TCacheScanThread.ScanPath(const APath: String);
var
  P, Ext: String;
begin
  if Terminated then Exit;
  P := Trim(APath);
  if (Length(P) >= 2) and (P[1] = '"') and (P[Length(P)] = '"') then
    P := Copy(P, 2, Length(P) - 2);
  if P = '' then Exit;

  if DirectoryExists(P) then
    ScanFolder(P)
  else if FileExists(P) then
  begin
    Inc(FScannedFiles);
    Ext := LowerCase(ExtractFileExt(P));
    if (Ext = '.idf') or (Ext = '.xml') then
      FFound.Add(P);
  end;
end;

procedure TCacheScanThread.ScanFolder(const Folder: String);
var
  SR: TSearchRec;
  Path, Ext: String;
begin
  if Terminated then Exit;
  Inc(FScannedFolders);
  FCurrent := Folder;
  if (FScannedFolders mod 5) = 0 then
    Synchronize(@SyncProgress);

  if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if Terminated then Break;
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Path := IncludeTrailingPathDelimiter(Folder) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          ScanFolder(Path)
        else
        begin
          Inc(FScannedFiles);
          Ext := LowerCase(ExtractFileExt(Path));
          if (Ext = '.idf') or (Ext = '.xml') then
            FFound.Add(Path);
          if (FScannedFiles mod 50) = 0 then
            Synchronize(@SyncProgress);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TCacheScanThread.SyncProgress;
begin
  if Assigned(FOwner) then
    FOwner.CacheScanProgress(FScannedFolders, FScannedFiles, FFound.Count, FCurrent);
end;

procedure TCacheScanThread.SyncDone;
begin
  if Assigned(FOwner) then
    FOwner.CacheScanDone(FFound, FScannedFolders, FScannedFiles, Terminated);
end;

procedure TCacheScanThread.Execute;
var
  i: Integer;
begin
  Synchronize(@SyncProgress);
  for i := 0 to FRoots.Count - 1 do
  begin
    if Terminated then Break;
    ScanPath(FRoots[i]);
  end;
  Synchronize(@SyncDone);
end;

constructor TMainForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  SetAppTitle;
  Width    := 1280;
  Height   := 800;
  Position := poScreenCenter;
  KeyPreview := True;
  OnKeyDown := @OnFormKeyDown;

  InitRollData(FRollData);
  FDirty := False;
  FCurrentIDFPath := '';
  FCurrentProjectPath := '';
  FUndoDetectFrames := nil;
  FDetectCancel := False;
  FDetectRunning := False;
  FExportCancel := False;
  FExportPaused := False;
  FExportRunning := False;
  FExportRunId := 0;
  FExportLastProgressTick := GetTickCount64;
  FExportLastDoneCount := 0;
  FExportWatchdogTimer := TTimer.Create(Self);
  FExportWatchdogTimer.Enabled := False;
  FExportWatchdogTimer.Interval := 5000;
  FExportWatchdogTimer.OnTimer := @OnExportWatchdog;
  FExportTracePath := '';
  FExportLastTrace := '';
  FExportFailedFrames := nil;
  FExportFailedErrors := nil;
  FExportRetryFailedOnly := False;
  InitCriticalSection(FExportLock);
  InitCriticalSection(FExportBuildLock);
  InitCriticalSection(FExportSaveLock);
  FApplyingZoom := False;
  FUpdatingExportNaming := False;
  FApplyingPreviewZoom := False;
  FPreviewFrameIdx := -1;
  FPreviewZoomPct := 0;
  FPreviewKeepFullRes := False;
  FPreviewKeepOneToOne := False;
  FPreviewKeepTopMost := False;
  FAutoLayoutUpdating := False;
  FUpdatingDetectRange := False;
  FUpdatingAdjustments := False;

  BuildMainMenu;
  FCacheQueuePaths := TStringList.Create;
  LoadCacheQueue;
  BuildToolPanel;
  BuildLayout;
  BuildStripView;
  BuildRightPanel;
  BuildStatusBar;

  UpdateNavButtons;
  UpdateStatus;
end;

function TMainForm.AppTitlePrefix: String;
begin
  Result := STRIPLIGHT_TITLE;
end;

procedure TMainForm.SetAppTitle(const Suffix: String);
begin
  if Suffix = '' then
    Caption := AppTitlePrefix
  else
    Caption := AppTitlePrefix + ' - ' + Suffix;
end;

destructor TMainForm.Destroy;
begin
  StopCacheScan(False);
  StopBackgroundCache(False);
  SaveCacheQueue;
  FCacheQueuePaths.Free;
  DoneCriticalsection(FExportSaveLock);
  DoneCriticalsection(FExportBuildLock);
  DoneCriticalsection(FExportLock);
  inherited Destroy;
end;

{ ============================================================ }
{ UI helpers                                                    }
{ ============================================================ }

function TMainForm.MakeLabel(AParent: TWinControl; const ACaption: String;
                              X, Y: Integer): TLabel;
begin
  Result := TLabel.Create(Self);
  Result.Parent   := AParent;
  Result.Caption  := ACaption;
  Result.Left     := X;
  Result.Top      := Y;
  Result.AutoSize := True;
end;

function TMainForm.MakeButton(AParent: TWinControl; const ACaption: String;
                               X, Y, W, H: Integer;
                               Handler: TNotifyEvent): TBitBtn;
begin
  Result := TBitBtn.Create(Self);
  Result.Parent  := AParent;
  Result.Caption := ButtonCaptionWithIcon(ACaption);
  ApplyButtonStyle(Result);
  ApplyButtonGlyph(Result, ACaption);
  Result.Left    := X;
  Result.Top     := Y;
  Result.Width   := W;
  Result.Height  := H;
  Result.OnClick := Handler;
end;

function TMainForm.MakeGroupBox(AParent: TWinControl; const ACaption: String;
                                 X, Y, W, H: Integer): TGroupBox;
begin
  Result := TGroupBox.Create(Self);
  Result.Parent  := AParent;
  Result.Caption := ACaption;
  Result.Left    := X;
  Result.Top     := Y;
  Result.Width   := W;
  Result.Height  := H;
end;

function TMainForm.MakeTrack(AParent: TWinControl; X, Y, W: Integer;
                              Lo, Hi, Pos: Integer): TTrackBar;
var
  Range: Integer;
begin
  Result := TTrackBar.Create(Self);
  Result.Parent    := AParent;
  Result.Left      := X;
  Result.Top       := Y;
  Result.Width     := W;
  Result.Height    := 24;
  Result.Min       := Lo;
  Result.Max       := Hi;
  Result.Position  := Pos;
  Result.TickStyle := tsNone;
  Range := Abs(Hi - Lo);
  Result.LineSize  := Max(1, Range div 50);
  Result.PageSize  := Max(5, Range div 10);
end;

procedure TMainForm.ConfigureTabScrollBox(Scroll: TScrollBox);
begin
  if not Assigned(Scroll) then Exit;
  Scroll.VertScrollBar.Increment := 72;
  Scroll.HorzScrollBar.Increment := 72;
  Scroll.OnMouseWheel := @OnTabScrollMouseWheel;
end;

{ ============================================================ }
{ Main menu                                                     }
{ ============================================================ }

procedure TMainForm.BuildMainMenu;
var
  MFile, MView, MTools, MHelp: TMenuItem;
  MI, Sep: TMenuItem;
begin
  FMainMenu := TMainMenu.Create(Self);
  Self.Menu := FMainMenu;

  { ── File ── }
  MFile := TMenuItem.Create(FMainMenu);
  MFile.Caption := '&File';
  FMainMenu.Items.Add(MFile);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := '&Open...';
  MI.ShortCut := ShortCut(Ord('O'), [ssCtrl]);
  MI.OnClick  := @OnOpen;
  MFile.Add(MI);

  Sep := TMenuItem.Create(FMainMenu); Sep.Caption := '-'; MFile.Add(Sep);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := '&Save';
  MI.ShortCut := ShortCut(Ord('S'), [ssCtrl]);
  MI.OnClick  := @OnSave;
  MFile.Add(MI);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := 'Save &As...';
  MI.ShortCut := ShortCut(Ord('S'), [ssCtrl, ssShift]);
  MI.OnClick  := @OnSaveAs;
  MFile.Add(MI);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := 'Save &QPF As...';
  MI.OnClick  := @OnSaveQPFAs;
  MFile.Add(MI);

  Sep := TMenuItem.Create(FMainMenu); Sep.Caption := '-'; MFile.Add(Sep);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := 'E&xit';
  MI.ShortCut := ShortCut(VK_F4, [ssAlt]);
  MI.OnClick  := @OnExitApp;
  MFile.Add(MI);

  { ── View ── }
  MView := TMenuItem.Create(FMainMenu);
  MView.Caption := '&View';
  FMainMenu.Items.Add(MView);

  FMenuMIStripEdges := TMenuItem.Create(FMainMenu);
  FMenuMIStripEdges.Caption   := 'Show &Strip Edges';
  FMenuMIStripEdges.AutoCheck := True;
  FMenuMIStripEdges.Checked   := False;
  FMenuMIStripEdges.OnClick   := @OnViewStripEdges;
  MView.Add(FMenuMIStripEdges);

  Sep := TMenuItem.Create(FMainMenu); Sep.Caption := '-'; MView.Add(Sep);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption  := '&Go To Frame / Page...';
  MI.ShortCut := ShortCut(Ord('G'), [ssCtrl]);
  MI.OnClick  := @OnGoTo;
  MView.Add(MI);

  { ── Tools ── }
  MTools := TMenuItem.Create(FMainMenu);
  MTools.Caption := '&Tools';
  FMainMenu.Items.Add(MTools);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption := '&Settings...';
  MI.OnClick := @OnSettings;
  MTools.Add(MI);

  { ── Help ── }
  MHelp := TMenuItem.Create(FMainMenu);
  MHelp.Caption := '&Help';
  FMainMenu.Items.Add(MHelp);

  MI := TMenuItem.Create(FMainMenu);
  MI.Caption := '&About Striplight...';
  MI.OnClick := @OnAbout;
  MHelp.Add(MI);
end;

{ ============================================================ }
{ Toolbar (flat TPanel)                                         }
{ ============================================================ }

procedure TMainForm.BuildToolPanel;
var
  SourceGrp, NavGrp, ViewGrp, ZoomGrp: TGroupBox;

  function SB(AParent: TWinControl; const Cap: String; ALeft, ATop, AWidth: Integer;
               Evt: TNotifyEvent; const HintText: String = ''): TSpeedButton;
  begin
    Result := TSpeedButton.Create(Self);
    Result.Parent  := AParent;
    Result.Caption := ButtonCaptionWithIcon(Cap);
    ApplySpeedButtonStyle(Result);
    ApplySpeedButtonGlyph(Result, Cap);
    Result.Left    := ALeft;
    Result.Top     := ATop;
    Result.Width   := AWidth;
    Result.Height  := 26;
    Result.Flat    := True;
    Result.OnClick := Evt;
    if HintText <> '' then
    begin
      Result.Hint := HintText;
      Result.ShowHint := True;
    end;
  end;

  function MakeToolbarLabel(AParent: TWinControl; const Cap: String; ALeft, ATop: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := AParent;
    Result.Caption := Cap;
    Result.Left := ALeft;
    Result.Top := ATop;
    Result.AutoSize := True;
  end;

  function MakeToolbarCheck(AParent: TWinControl; const Cap: String; ALeft, ATop, AWidth: Integer;
    Checked: Boolean; Evt: TNotifyEvent; const HintText: String = ''): TCheckBox;
  begin
    Result := TCheckBox.Create(Self);
    Result.Parent := AParent;
    Result.Caption := Cap;
    Result.Left := ALeft;
    Result.Top := ATop;
    Result.Width := AWidth;
    Result.Checked := Checked;
    Result.OnChange := Evt;
    if HintText <> '' then
    begin
      Result.Hint := HintText;
      Result.ShowHint := True;
    end;
  end;

begin
  FToolPanel := TPanel.Create(Self);
  FToolPanel.Parent      := Self;
  FToolPanel.Align       := alTop;
  FToolPanel.Height      := 184;
  FToolPanel.BevelOuter  := bvNone;
  FToolPanel.Color       := clBtnFace;
  FToolPanel.Caption     := '';

  SourceGrp := MakeGroupBox(FToolPanel, 'Source', 8, 2, 306, 88);
  FBtnOpen  := SB(SourceGrp, 'Open...', 12, 8, 80, @OnOpen, 'Open IDF, SLF, or QPF');
  FBtnSave  := SB(SourceGrp, 'Save', 100, 8, 68, @OnSave, 'Save current SLF project');
  FBtnCacheManager := SB(SourceGrp, 'Cache...', 176, 8, 76, @OnCacheManager, 'Open preview cache manager');
  FChkCachePreviews := MakeToolbarCheck(SourceGrp, 'Cache previews', 12, 34, 118, False,
    @OnCachePreviewsToggle, 'Use local preview cache; detection copies missing previews on demand');
  FBtnBgCache := SB(SourceGrp, 'Start Cache', 132, 32, 96, @OnBackgroundCache,
    'Fill this project preview cache in the background');
  FBtnClearCaches := SB(SourceGrp, 'Clear', 234, 32, 64, @OnClearPreviewCaches,
    'Delete all local preview cache folders');

  NavGrp := MakeGroupBox(FToolPanel, 'Navigation', 320, 2, 300, 88);
  FBtnFirst := SB(NavGrp, '|<', 12, 18, 38, @OnFirst, 'First page');
  FBtnPrev  := SB(NavGrp, '<',  58, 18, 38, @OnPrev,  'Previous page');
  FBtnNext  := SB(NavGrp, '>',  104, 18, 38, @OnNext,  'Next page');
  FBtnLast  := SB(NavGrp, '>|', 150, 18, 38, @OnLast,  'Last page');
  FLblPageJump := MakeToolbarLabel(NavGrp, 'Page', 206, 8);

  FSpinPageJump := TSpinEdit.Create(Self);
  FSpinPageJump.Parent   := NavGrp;
  FSpinPageJump.Left     := 206;
  FSpinPageJump.Top      := 28;
  FSpinPageJump.Width    := 58;
  FSpinPageJump.Height   := 26;
  FSpinPageJump.MinValue := 1;
  FSpinPageJump.MaxValue := 1;
  FSpinPageJump.Value    := 1;
  FSpinPageJump.OnKeyDown := @OnPageJumpKeyDown;

  ViewGrp := MakeGroupBox(FToolPanel, 'View', 632, 2, 252, 88);
  FLblStrips := MakeToolbarLabel(ViewGrp, 'Strips/row', 12, 8);

  FSpinStrips := TSpinEdit.Create(Self);
  FSpinStrips.Parent   := ViewGrp;
  FSpinStrips.Left     := 82;
  FSpinStrips.Top      := 4;
  FSpinStrips.Width    := 50;
  FSpinStrips.Height   := 26;
  FSpinStrips.MinValue := 1;
  FSpinStrips.MaxValue := 20;
  FSpinStrips.Value    := 4;
  FSpinStrips.OnKeyDown := @OnStripsKeyDown;
  FChkAutoStrips := MakeToolbarCheck(ViewGrp, 'Auto', 140, 7, 52, False, @OnAutoStripsToggle,
    'Automatically choose strips per row');
  FBtnRotate := SB(ViewGrp, 'Rot CCW', 12, 32, 72, @OnRotateToggle, 'Toggle clockwise/counterclockwise rotation');
  FChkMultiManip := MakeToolbarCheck(ViewGrp, 'Multi-edit', 96, 36, 82, False,
    @OnMultiManipToggle, 'When checked, dragging a handle moves/resizes all selected frames together');

  ZoomGrp := MakeGroupBox(FToolPanel, 'Zoom', 896, 2, 284, 88);
  FLblZoom := MakeToolbarLabel(ZoomGrp, 'Zoom', 12, 20);

  FTrackZoom := MakeTrack(ZoomGrp, 58, 16, 140, 25, 400, 100);
  FTrackZoom.OnChange := @OnZoomChanged;

  FSpinZoom := TSpinEdit.Create(Self);
  FSpinZoom.Parent   := ZoomGrp;
  FSpinZoom.Left     := 208;
  FSpinZoom.Top      := 14;
  FSpinZoom.Width    := 58;
  FSpinZoom.Height   := 26;
  FSpinZoom.MinValue := 25;
  FSpinZoom.MaxValue := 400;
  FSpinZoom.Value    := 100;
  FSpinZoom.OnKeyDown := @OnZoomKeyDown;

  FTopSnapshotGrp := MakeGroupBox(FToolPanel, 'Project Snapshot', 8, 92, Max(420, ClientWidth - 16), 84);
  FTopSnapshotGrp.Anchors := [akLeft, akTop, akRight];
  FLblMetricFrames := MakeToolbarLabel(FTopSnapshotGrp, 'Frames: -', 12, 14);
  FLblMetricSelection := MakeToolbarLabel(FTopSnapshotGrp, 'Selected: -', 112, 14);
  FLblMetricRoll := MakeToolbarLabel(FTopSnapshotGrp, 'Roll: no roll loaded', 328, 14);
  FLblMetricPreview := MakeToolbarLabel(FTopSnapshotGrp, 'Output: select or load a roll', 12, 38);
  FLblMetricPreview.AutoSize := False;
  FLblMetricPreview.Width := Max(220, FTopSnapshotGrp.Width - 24);
  FLblMetricPreview.Height := 18;
  FLblMetricPreview.Anchors := [akLeft, akTop, akRight];
end;

{ ============================================================ }
{ Main layout                                                   }
{ ============================================================ }

procedure TMainForm.BuildLayout;
begin
  { Right panel (sidebar) – must be created before alClient panel }
  FRightPanel := TPanel.Create(Self);
  FRightPanel.Parent     := Self;
  FRightPanel.Align      := alRight;
  FRightPanel.Width      := 346;
  FRightPanel.BevelOuter := bvNone;

  { Splitter between left and right }
  FMainSplitter := TSplitter.Create(Self);
  FMainSplitter.Parent := Self;
  FMainSplitter.Align  := alRight;
  FMainSplitter.Width  := 4;

  { Left panel – strip view goes here }
  FLeftPanel := TPanel.Create(Self);
  FLeftPanel.Parent     := Self;
  FLeftPanel.Align      := alClient;
  FLeftPanel.BevelOuter := bvNone;
  FLeftPanel.Color      := $101010;
  FLeftPanel.OnResize   := @OnLeftPanelResize;
end;

{ ============================================================ }
{ Strip view                                                    }
{ ============================================================ }

procedure TMainForm.BuildStripView;
begin
  FStripView := TStripView.Create(Self);
  FStripView.Parent              := FLeftPanel;
  FStripView.Align               := alClient;
  FStripView.StripsPerRow        := 4;
  FStripView.Zoom                := 1.0;
  FStripView.OnPageChanged       := @OnPageChanged;
  FStripView.OnSelectionChanged  := @OnSelectionChanged;
  FStripView.OnFrameDblClick     := @OnFrameDblClick;
  FStripView.OnFrameChanged      := @OnFrameChanged;
  FStripView.OnExportMarkChanged := @OnExportMarkChanged;
  FStripView.OnSelectFrameSection := @OnSelectFrameSection;
  FStripView.OnDeleteFrameSection := @OnDeleteFrameSection;
  FStripView.OnTrimChanged       := @OnTrimViewChanged;
  FStripView.OnDetectRangeChanged := @OnDetectRangeViewChanged;
  FStripView.OnDetectAreaChanged := @OnDetectAreaChanged;
  FStripView.OnKeyDown           := @OnFormKeyDown;
end;

{ ============================================================ }
{ Right panel / tabs                                            }
{ ============================================================ }

procedure TMainForm.BuildRightPanel;
begin
  FPageCtrl := TPageControl.Create(Self);
  FPageCtrl.Parent := FRightPanel;
  FPageCtrl.Align  := alClient;

  FTabDetect  := FPageCtrl.AddTabSheet; FTabDetect.Caption  := 'Detect';
  FTabFraming := FPageCtrl.AddTabSheet; FTabFraming.Caption := 'Framing';
  FTabProcess := FPageCtrl.AddTabSheet; FTabProcess.Caption := 'Process';
  FTabFiles   := FPageCtrl.AddTabSheet; FTabFiles.Caption   := 'Files';

  BuildDetectTab;
  BuildFramingTab;
  BuildProcessTab;
  BuildFilesTab;
end;

{ ============================================================ }
{ Detect tab                                                    }
{ ============================================================ }

procedure TMainForm.BuildDetectTab;
var
  Y: Integer;
  ScopeGrp, ThrGrp, AreaGrp, ActionGrp: TGroupBox;
  Scroll: TScrollBox;
  Spacer: TPanel;
begin
  Scroll := TScrollBox.Create(Self);
  Scroll.Parent      := FTabDetect;
  Scroll.Align       := alClient;
  Scroll.BorderStyle := bsNone;
  Scroll.AutoScroll  := True;
  ConfigureTabScrollBox(Scroll);
  Y := 8;

  ScopeGrp := MakeGroupBox(Scroll, 'Detection Scope', 4, Y, 304, 112);
  FDetectScopeGrp := ScopeGrp;

  FRbDetectFull := TRadioButton.Create(Self);
  FRbDetectFull.Parent  := ScopeGrp;
  FRbDetectFull.Caption := 'Full Roll';
  FRbDetectFull.Left    := 8;  FRbDetectFull.Top  := 18;
  FRbDetectFull.Checked := True;
  FRbDetectFull.OnChange := @OnDetectRangeControlChanged;

  FRbDetectRange := TRadioButton.Create(Self);
  FRbDetectRange.Parent  := ScopeGrp;
  FRbDetectRange.Caption := 'Limit Range';
  FRbDetectRange.Left    := 8;  FRbDetectRange.Top  := 36;
  FRbDetectRange.OnChange := @OnDetectRangeControlChanged;

  MakeLabel(ScopeGrp, 'From:', 8, 58);
  FEdtRangeFrom := TSpinEdit.Create(Self);
  FEdtRangeFrom.Parent   := ScopeGrp;
  FEdtRangeFrom.Left     := 48;  FEdtRangeFrom.Top  := 54;
  FEdtRangeFrom.Width    := 60;
  FEdtRangeFrom.MinValue := 0;   FEdtRangeFrom.MaxValue := 99999;
  FEdtRangeFrom.OnChange := @OnDetectRangeControlChanged;

  MakeLabel(ScopeGrp, 'To:', 118, 58);
  FEdtRangeTo := TSpinEdit.Create(Self);
  FEdtRangeTo.Parent   := ScopeGrp;
  FEdtRangeTo.Left     := 138;  FEdtRangeTo.Top  := 54;
  FEdtRangeTo.Width    := 60;
  FEdtRangeTo.MinValue := 0;    FEdtRangeTo.MaxValue := 99999;
  FEdtRangeTo.OnChange := @OnDetectRangeControlChanged;

  Inc(Y, 122);

  ThrGrp := MakeGroupBox(Scroll, 'Thresholds', 4, Y, 304, 100);
  MakeLabel(ThrGrp, 'Min Width:',  8, 20);
  FSpinMinW := TSpinEdit.Create(Self);
  FSpinMinW.Parent   := ThrGrp;
  FSpinMinW.Left     := 80;  FSpinMinW.Top    := 16;
  FSpinMinW.Width    := 60;  FSpinMinW.Value  := 50;
  FSpinMinW.MinValue := 1;   FSpinMinW.MaxValue := 9999;

  MakeLabel(ThrGrp, 'Min Height:', 8, 46);
  FSpinMinH := TSpinEdit.Create(Self);
  FSpinMinH.Parent   := ThrGrp;
  FSpinMinH.Left     := 80;  FSpinMinH.Top    := 42;
  FSpinMinH.Width    := 60;  FSpinMinH.Value  := 50;
  FSpinMinH.MinValue := 1;   FSpinMinH.MaxValue := 9999;

  Inc(Y, 110);

  AreaGrp := MakeGroupBox(Scroll, 'Detection Area', 4, Y, 304, 122);
  FChkDetectAreaEnable := TCheckBox.Create(Self);
  FChkDetectAreaEnable.Parent := AreaGrp;
  FChkDetectAreaEnable.Caption := 'Use edge limits';
  FChkDetectAreaEnable.Left := 8;
  FChkDetectAreaEnable.Top := 18;
  FChkDetectAreaEnable.Width := 130;
  FChkDetectAreaEnable.Checked := False;
  FChkDetectAreaEnable.OnChange := @OnDetectAreaChanged;
  MakeLabel(AreaGrp, 'Drag blue lines or type px', 142, 20);

  MakeLabel(AreaGrp, 'Ignore top edge:', 8, 48);
  FSpinDetectIgnoreTop := TSpinEdit.Create(Self);
  FSpinDetectIgnoreTop.Parent := AreaGrp;
  FSpinDetectIgnoreTop.Left := 112;
  FSpinDetectIgnoreTop.Top := 44;
  FSpinDetectIgnoreTop.Width := 68;
  FSpinDetectIgnoreTop.MinValue := 0;
  FSpinDetectIgnoreTop.MaxValue := 999999;
  FSpinDetectIgnoreTop.Value := 0;
  FSpinDetectIgnoreTop.OnChange := @OnDetectAreaChanged;
  MakeLabel(AreaGrp, 'px', 188, 48);

  MakeLabel(AreaGrp, 'Ignore bottom edge:', 8, 76);
  FSpinDetectIgnoreBottom := TSpinEdit.Create(Self);
  FSpinDetectIgnoreBottom.Parent := AreaGrp;
  FSpinDetectIgnoreBottom.Left := 112;
  FSpinDetectIgnoreBottom.Top := 72;
  FSpinDetectIgnoreBottom.Width := 68;
  FSpinDetectIgnoreBottom.MinValue := 0;
  FSpinDetectIgnoreBottom.MaxValue := 999999;
  FSpinDetectIgnoreBottom.Value := 0;
  FSpinDetectIgnoreBottom.OnChange := @OnDetectAreaChanged;
  MakeLabel(AreaGrp, 'px', 188, 76);
  FBtnDetectAreaReset := MakeButton(AreaGrp, 'Reset', 220, 68, 68, 25, @OnDetectAreaReset);
  Inc(Y, 132);

  ActionGrp := MakeGroupBox(Scroll, 'Detection Actions', 4, Y, 304, 178);

  FChkDetectLivePreview := TCheckBox.Create(Self);
  FChkDetectLivePreview.Parent  := ActionGrp;
  FChkDetectLivePreview.Caption := 'Live detection preview';
  FChkDetectLivePreview.Left    := 8;
  FChkDetectLivePreview.Top     := 20;
  FChkDetectLivePreview.Width   := 220;
  FChkDetectLivePreview.Checked := False;

  FBtnDetectStart := MakeButton(ActionGrp, 'Start Detection', 8, 48, 160, 28, @OnDetectStart);
  FBtnDetectStop  := MakeButton(ActionGrp, 'Stop', 176, 48, 112, 28, @OnDetectStop);
  FBtnDetectStop.Enabled := False;

  FBtnDetectUndo := MakeButton(ActionGrp, 'Undo Last Change', 8, 84, 280, 28, @OnDetectUndo);
  FBtnDetectUndo.Enabled := False;

  FProgressDetect := TProgressBar.Create(Self);
  FProgressDetect.Parent := ActionGrp;
  FProgressDetect.Left   := 8;
  FProgressDetect.Top    := 120;
  FProgressDetect.Width  := 280;
  FProgressDetect.Height := 20;
  FProgressDetect.Min    := 0;
  FProgressDetect.Max    := 100;
  FProgressDetect.Position := 0;

  FLblDetectStatus := MakeLabel(ActionGrp, 'Ready.', 8, 142);
  FLblDetectStatus.AutoSize := False;
  FLblDetectStatus.WordWrap := True;
  FLblDetectStatus.Width := 280;
  FLblDetectStatus.Height := 18;
  Inc(Y, 188);
  Spacer := TPanel.Create(Self);
  Spacer.Parent := Scroll;
  Spacer.Left := 4;
  Spacer.Top := Y;
  Spacer.Width := 1;
  Spacer.Height := 1;
  Spacer.BevelOuter := bvNone;
end;

{ ============================================================ }
{ Framing tab                                                   }
{ ============================================================ }

procedure TMainForm.BuildFramingTab;
var
  Y: Integer;
  SelGrp, DelGrp, OverlayGrp, MarkGrp, MarkerCleanGrp, SugCleanGrp, DetGrp, OvlGrp, RepairGrp, SplitGrp, TrimGrp: TGroupBox;
  Scroll: TScrollBox;
begin
  Scroll := TScrollBox.Create(Self);
  Scroll.Parent      := FTabFraming;
  Scroll.Align       := alClient;
  Scroll.BorderStyle := bsNone;
  Scroll.AutoScroll  := True;
  ConfigureTabScrollBox(Scroll);
  Y := 8;

  SelGrp := MakeGroupBox(Scroll, 'Select', 4, Y, 304, 96);
  FBtnSelPage := MakeButton(SelGrp, 'Select Page',  8,  18, 136, 25, @OnSelectPage);
  FBtnSelAll  := MakeButton(SelGrp, 'Select All',   8,  48, 136, 25, @OnSelectAll);
  FBtnSelNone := MakeButton(SelGrp, 'Unselect All', 152, 18, 136, 25, @OnSelectNone);
  Inc(Y, 106);

  DelGrp := MakeGroupBox(Scroll, 'Delete', 4, Y, 304, 90);
  FBtnDeleteSelected := MakeButton(DelGrp, 'Delete Selected (D)', 8, 18, 180, 25, @OnDeleteSelected);
  FBtnDeleteAll      := MakeButton(DelGrp, 'Delete All',      8, 42, 180, 25, @OnDeleteAll);
  Inc(Y, 100);

  OverlayGrp := MakeGroupBox(Scroll, 'Frame Overlay', 4, Y, 304, 78);
  MakeLabel(OverlayGrp, 'Fill opacity:', 8, 22);
  FTrackFrameFillOpacity := MakeTrack(OverlayGrp, 96, 18, 156, 0, 100, 35);
  FTrackFrameFillOpacity.OnChange := @OnFrameFillOpacityChanged;
  FTrackFrameFillOpacity.OnMouseDown := @OnVisualSliderMouseDown;
  FTrackFrameFillOpacity.OnMouseUp := @OnVisualSliderRelease;
  FLblFrameFillOpacity := MakeLabel(OverlayGrp, '35%', 260, 22);
  Inc(Y, 88);

  MarkGrp := MakeGroupBox(Scroll, 'Folder Markers (0)', 4, Y, 304, 346);
  FGrpMarkers := MarkGrp;
  FLblMarkerCount := MakeLabel(MarkGrp, 'Markers in project: 0', 8, 20);
  FBtnMarkFolder := MakeButton(MarkGrp, 'Mark as Folder Start (A)', 8, 44, 280, 25, @OnMarkFolder);

  MakeLabel(MarkGrp, 'Auto-suggest strictness:', 8, 80);
  FLblSuggestSensitivity := MakeLabel(MarkGrp, '50', 258, 80);
  FTrackSensitivity := MakeTrack(MarkGrp, 8, 94, 280, 10, 200, 50);
  FTrackSensitivity.OnChange := @OnSuggestSensitivityChanged;
  FLblSuggestSensitivity.Caption := IntToStr(FTrackSensitivity.Position);

  FChkSuggestBeforeGap := TCheckBox.Create(Self);
  FChkSuggestBeforeGap.Parent := MarkGrp;
  FChkSuggestBeforeGap.Caption := 'Suggest frame before gap';
  FChkSuggestBeforeGap.Left := 8;
  FChkSuggestBeforeGap.Top := 116;
  FChkSuggestBeforeGap.Width := 220;
  FChkSuggestBeforeGap.Checked := True;
  FChkSuggestBeforeGap.OnChange := @OnSuggestSensitivityChanged;

  FBtnSuggestMarkers := MakeButton(MarkGrp, 'Suggest Markers', 8, 140, 280, 25, @OnSuggestMarkers);
  FBtnSuggestStart := MakeButton(MarkGrp, 'Suggest Start', 8, 170, 136, 25, @OnSuggestMarkers);
  FBtnSuggestStart.Tag := -1;
  FBtnSuggestEnd := MakeButton(MarkGrp, 'Suggest End', 152, 170, 136, 25, @OnSuggestMarkers);
  FBtnSuggestEnd.Tag := 1;
  FBtnSelectSuggested := MakeButton(MarkGrp, 'Select All Suggested',    8, 210, 280, 25, @OnSelectSuggested);
  FBtnClearSelectedSuggested := MakeButton(MarkGrp, 'Clear Selected Suggestions', 8, 240, 280, 25, @OnClearSelectedSuggested);
  FBtnClearSuggested  := MakeButton(MarkGrp, 'Clear All Suggestions',   8, 270, 280, 25, @OnClearSuggested);
  Inc(Y, 356);

  MarkerCleanGrp := MakeGroupBox(Scroll, 'Yellow Marker Cleanup', 4, Y, 304, 104);
  FBtnClearMarkers := MakeButton(MarkerCleanGrp, 'Clear All Yellow Markers', 8, 18, 280, 25, @OnClearMarkers);
  FBtnClearMarkersStart := MakeButton(MarkerCleanGrp, 'Clear toward Start', 8, 48, 136, 25, @OnClearMarkersDirection);
  FBtnClearMarkersStart.Tag := -1;
  FBtnClearMarkersEnd := MakeButton(MarkerCleanGrp, 'Clear toward End', 152, 48, 136, 25, @OnClearMarkersDirection);
  FBtnClearMarkersEnd.Tag := 1;
  Inc(Y, 114);

  SugCleanGrp := MakeGroupBox(Scroll, 'Suggested Cleanup', 4, Y, 304, 104);
  MakeLabel(SugCleanGrp, 'Every N:', 8, 22);
  FSpinSuggestClearEvery := TSpinEdit.Create(Self);
  FSpinSuggestClearEvery.Parent := SugCleanGrp;
  FSpinSuggestClearEvery.Left := 72;
  FSpinSuggestClearEvery.Top := 18;
  FSpinSuggestClearEvery.Width := 56;
  FSpinSuggestClearEvery.MinValue := 1;
  FSpinSuggestClearEvery.MaxValue := 999;
  FSpinSuggestClearEvery.Value := 2;
  FBtnClearSuggestStart := MakeButton(SugCleanGrp, 'Clear toward Start', 8, 48, 136, 25, @OnClearSuggestedEvery);
  FBtnClearSuggestStart.Tag := -1;
  FBtnClearSuggestEnd := MakeButton(SugCleanGrp, 'Clear toward End', 152, 48, 136, 25, @OnClearSuggestedEvery);
  FBtnClearSuggestEnd.Tag := 1;
  Inc(Y, 114);

  { ── Detect Oversized / Undersized Frames ── }
  DetGrp := MakeGroupBox(Scroll, 'Detect Oversized / Undersized Frames', 4, Y, 304, 190);

  FChkShowOversized := TCheckBox.Create(Self);
  FChkShowOversized.Parent   := DetGrp;
  FChkShowOversized.Caption  := 'Show Oversized';
  FChkShowOversized.Left     := 8;   FChkShowOversized.Top    := 20;
  FChkShowOversized.Width    := 96;  FChkShowOversized.Checked := True;
  FChkShowOversized.OnChange := @OnDetectSizeChanged;

  FTrackOversized := MakeTrack(DetGrp, 118, 18, 128, 0, 200, 50);
  FTrackOversized.OnChange := @OnDetectSizeChanged;
  FTrackOversized.OnMouseDown := @OnVisualSliderMouseDown;
  FTrackOversized.OnMouseUp := @OnVisualSliderRelease;
  FLblOverPct := MakeLabel(DetGrp, '50', 256, 22);

  FChkShowUndersized := TCheckBox.Create(Self);
  FChkShowUndersized.Parent   := DetGrp;
  FChkShowUndersized.Caption  := 'Show Undersized';
  FChkShowUndersized.Left     := 8;   FChkShowUndersized.Top    := 50;
  FChkShowUndersized.Width    := 96;  FChkShowUndersized.Checked := True;
  FChkShowUndersized.OnChange := @OnDetectSizeChanged;

  FTrackUndersized := MakeTrack(DetGrp, 118, 48, 128, 0, 99, 50);
  FTrackUndersized.OnChange := @OnDetectSizeChanged;
  FTrackUndersized.OnMouseDown := @OnVisualSliderMouseDown;
  FTrackUndersized.OnMouseUp := @OnVisualSliderRelease;
  FLblUnderPct := MakeLabel(DetGrp, '50', 256, 52);

  MakeLabel(DetGrp, 'percent above / below median frame height', 8, 78);
  FBtnSelectBySize := MakeButton(DetGrp, 'Select Flagged Frames', 8, 110, 280, 24, @OnSelectBySize);
  FBtnJumpSmall := MakeButton(DetGrp, 'Next Small', 8, 140, 88, 24, @OnJumpAttentionFrame);
  FBtnJumpSmall.Tag := -1;
  FBtnJumpBig := MakeButton(DetGrp, 'Next Big', 104, 140, 88, 24, @OnJumpAttentionFrame);
  FBtnJumpBig.Tag := 1;
  FBtnJumpRed := MakeButton(DetGrp, 'Next Red', 200, 140, 88, 24, @OnJumpAttentionFrame);
  FBtnJumpRed.Tag := 0;
  Inc(Y, 200);

  { ── Overlapping Frames ── }
  OvlGrp := MakeGroupBox(Scroll, 'Overlapping Frames', 4, Y, 304, 138);
  FBtnCombineAll      := MakeButton(OvlGrp, 'Combine All Overlapping',
                                    8, 18, 280, 26, @OnCombineOverlapping);
  FBtnCombineSelected := MakeButton(OvlGrp, 'Combine Selected Overlapping (J)',
                                    8, 50, 280, 26, @OnCombineSelectedOverlapping);
  FBtnMergeAdjacent   := MakeButton(OvlGrp, 'Merge Adjacent Selected (Pairs) (E)',
                                    8, 82, 280, 26, @OnMergeAdjacent);
  Inc(Y, 148);

  { -- Manual repair for false frame splits / tight crops -- }
  RepairGrp := MakeGroupBox(Scroll, 'Frame Repair', 4, Y, 304, 244);
  MakeLabel(RepairGrp, 'Join selected if gap <=', 8, 22);
  FSpinJoinGap := TSpinEdit.Create(Self);
  FSpinJoinGap.Parent := RepairGrp;
  FSpinJoinGap.Left := 158;
  FSpinJoinGap.Top := 18;
  FSpinJoinGap.Width := 70;
  FSpinJoinGap.MinValue := 0;
  FSpinJoinGap.MaxValue := 999999;
  FSpinJoinGap.Value := 600;
  MakeLabel(RepairGrp, 'lines', 234, 22);
  FBtnJoinCloseSelected := MakeButton(RepairGrp, 'Join Close Selected',
                                      8, 48, 280, 25, @OnJoinCloseSelected);
  FBtnCloseSelectedGaps := MakeButton(RepairGrp, 'Close Gaps',
                                      8, 76, 280, 25, @OnCloseSelectedGaps);

  MakeLabel(RepairGrp, 'Expand selected frames:', 8, 112);
  MakeLabel(RepairGrp, 'Left', 8, 138);
  FSpinExpandTop := TSpinEdit.Create(Self);
  FSpinExpandTop.Parent := RepairGrp;
  FSpinExpandTop.Left := 42;
  FSpinExpandTop.Top := 134;
  FSpinExpandTop.Width := 54;
  FSpinExpandTop.MinValue := -999999;
  FSpinExpandTop.MaxValue := 999999;
  FSpinExpandTop.Value := 0;

  MakeLabel(RepairGrp, 'Right', 102, 138);
  FSpinExpandBottom := TSpinEdit.Create(Self);
  FSpinExpandBottom.Parent := RepairGrp;
  FSpinExpandBottom.Left := 154;
  FSpinExpandBottom.Top := 134;
  FSpinExpandBottom.Width := 54;
  FSpinExpandBottom.MinValue := -999999;
  FSpinExpandBottom.MaxValue := 999999;
  FSpinExpandBottom.Value := 0;

  MakeLabel(RepairGrp, 'Top', 8, 166);
  FSpinExpandLeft := TSpinEdit.Create(Self);
  FSpinExpandLeft.Parent := RepairGrp;
  FSpinExpandLeft.Left := 42;
  FSpinExpandLeft.Top := 162;
  FSpinExpandLeft.Width := 54;
  FSpinExpandLeft.MinValue := -999999;
  FSpinExpandLeft.MaxValue := 999999;
  FSpinExpandLeft.Value := 0;

  MakeLabel(RepairGrp, 'Bottom', 102, 166);
  FSpinExpandRight := TSpinEdit.Create(Self);
  FSpinExpandRight.Parent := RepairGrp;
  FSpinExpandRight.Left := 154;
  FSpinExpandRight.Top := 162;
  FSpinExpandRight.Width := 54;
  FSpinExpandRight.MinValue := -999999;
  FSpinExpandRight.MaxValue := 999999;
  FSpinExpandRight.Value := 0;

  FBtnExpandSelected := MakeButton(RepairGrp, 'Expand Selected',
                                   8, 192, 280, 25, @OnExpandSelected);
  Inc(Y, 264);

  { ── Split Frames ── }
  SplitGrp := MakeGroupBox(Scroll, 'Split Selected Frames', 4, Y, 304, 152);
  MakeLabel(SplitGrp, 'Split into N equal parts:', 8, 22);

  FSpinSplitN := TSpinEdit.Create(Self);
  FSpinSplitN.Parent   := SplitGrp;
  FSpinSplitN.Left     := 190; FSpinSplitN.Top   := 18;
  FSpinSplitN.Width    := 54;
  FSpinSplitN.MinValue := 2;  FSpinSplitN.MaxValue := 10000;
  FSpinSplitN.Value    := 2;
  FSpinSplitN.OnChange := @OnSplitPreviewChanged;

  FChkSplitPreview := TCheckBox.Create(Self);
  FChkSplitPreview.Parent := SplitGrp;
  FChkSplitPreview.Caption := 'Show split preview cuts';
  FChkSplitPreview.Left := 8;
  FChkSplitPreview.Top := 46;
  FChkSplitPreview.Width := 220;
  FChkSplitPreview.Checked := False;
  FChkSplitPreview.OnChange := @OnSplitPreviewChanged;

  FChkSplitConfirmMulti := TCheckBox.Create(Self);
  FChkSplitConfirmMulti.Parent := SplitGrp;
  FChkSplitConfirmMulti.Caption := 'Confirm multi-frame split';
  FChkSplitConfirmMulti.Left := 8;
  FChkSplitConfirmMulti.Top := 72;
  FChkSplitConfirmMulti.Width := 220;
  FChkSplitConfirmMulti.Checked := True;

  FBtnSplitFrame := MakeButton(SplitGrp, 'Split Selected Frames (S)', 8, 102, 280, 24, @OnSplitFrame);
  Inc(Y, 162);

  { ── Trim Top / Bottom ── }
  TrimGrp := MakeGroupBox(Scroll, 'Trim All Frames (Top / Bottom)', 4, Y, 304, 150);

  FChkTrimEnable := TCheckBox.Create(Self);
  FChkTrimEnable.Parent   := TrimGrp;
  FChkTrimEnable.Caption  := 'Show trim preview';
  FChkTrimEnable.Left     := 8;  FChkTrimEnable.Top  := 20;
  FChkTrimEnable.Width    := 200;
  FChkTrimEnable.OnChange := @OnTrimToggle;

  MakeLabel(TrimGrp, 'Trim top (px):', 8, 48);
  FSpinTrimTop := TSpinEdit.Create(Self);
  FSpinTrimTop.Parent   := TrimGrp;
  FSpinTrimTop.Left     := 126;  FSpinTrimTop.Top    := 44;
  FSpinTrimTop.Width    := 80;
  FSpinTrimTop.MinValue := 0;    FSpinTrimTop.MaxValue := 9999;
  FSpinTrimTop.Value    := 100;
  FSpinTrimTop.OnChange := @OnTrimSpinChanged;

  MakeLabel(TrimGrp, 'Trim bottom (px):', 8, 78);
  FSpinTrimBottom := TSpinEdit.Create(Self);
  FSpinTrimBottom.Parent   := TrimGrp;
  FSpinTrimBottom.Left     := 126;  FSpinTrimBottom.Top := 74;
  FSpinTrimBottom.Width    := 80;
  FSpinTrimBottom.MinValue := 0;    FSpinTrimBottom.MaxValue := 9999;
  FSpinTrimBottom.Value    := 100;
  FSpinTrimBottom.OnChange := @OnTrimSpinChanged;

  FBtnApplyTrim := MakeButton(TrimGrp, 'Apply Trim to All Frames',
                               8, 108, 280, 24, @OnApplyTrim);
end;

{ ============================================================ }
{ Process tab                                                   }
{ ============================================================ }

procedure TMainForm.BuildProcessTab;
var
  Y: Integer;
  PerFrameGrp, ProcGrp, AdjGrp, ScopeGrp, ExportActionGrp, ExportSettingsGrp: TGroupBox;
  Scroll: TScrollBox;
  Spacer: TPanel;
begin
  Scroll := TScrollBox.Create(Self);
  Scroll.Parent      := FTabProcess;
  Scroll.Align       := alClient;
  Scroll.BorderStyle := bsNone;
  Scroll.AutoScroll  := True;
  ConfigureTabScrollBox(Scroll);
  Y := 8;

  { ── Per-Frame Process Control ── }
  PerFrameGrp := MakeGroupBox(Scroll, 'Per-Frame (Selective) Process Control', 4, Y, 304, 136);

  FChkPerFrame := TCheckBox.Create(Self);
  FChkPerFrame.Parent   := PerFrameGrp;
  FChkPerFrame.Caption  := 'Enable Per-Frame Process Changes';
  FChkPerFrame.Left     := 8;  FChkPerFrame.Top   := 20;
  FChkPerFrame.Width    := 280;
  FChkPerFrame.OnChange := @OnPerFrameToggle;

  FBtnClearOverride := MakeButton(PerFrameGrp,
    'Reset / Clear All Per-Frame Changes', 8, 48, 280, 24, @OnClearPerFrameOverrides);
  FBtnClearOverride.Enabled := True;

  FBtnClearSelectedOverride := MakeButton(PerFrameGrp,
    'Clear Selected Per-Frame Changes', 8, 78, 280, 24, @OnClearSelectedPerFrameOverrides);
  FBtnClearSelectedOverride.Enabled := True;
  Inc(Y, 146);

  { ── Image Processing ── }
  ProcGrp := MakeGroupBox(Scroll, 'Image Processing', 4, Y, 304, 154);

  MakeLabel(ProcGrp, 'Rotation:', 8, 20);

  FRbRotM90 := TRadioButton.Create(Self);
  FRbRotM90.Parent := ProcGrp;  FRbRotM90.Caption := '-90°';
  FRbRotM90.Left := 8;   FRbRotM90.Top := 38; FRbRotM90.Width := 54;
  FRbRotM90.OnClick := @OnRotationChanged;

  FRbRot0 := TRadioButton.Create(Self);
  FRbRot0.Parent := ProcGrp;  FRbRot0.Caption := '0°';
  FRbRot0.Left := 66;  FRbRot0.Top := 38; FRbRot0.Width := 44;
  FRbRot0.Checked := True;
  FRbRot0.OnClick := @OnRotationChanged;

  FRbRot90 := TRadioButton.Create(Self);
  FRbRot90.Parent := ProcGrp;  FRbRot90.Caption := '90°';
  FRbRot90.Left := 114; FRbRot90.Top := 38; FRbRot90.Width := 44;
  FRbRot90.OnClick := @OnRotationChanged;

  FRbRot180 := TRadioButton.Create(Self);
  FRbRot180.Parent := ProcGrp;  FRbRot180.Caption := '180°';
  FRbRot180.Left := 162; FRbRot180.Top := 38; FRbRot180.Width := 54;
  FRbRot180.OnClick := @OnRotationChanged;

  FChkMirror := TCheckBox.Create(Self);
  FChkMirror.Parent  := ProcGrp;
  FChkMirror.Caption := 'Mirror (Horizontal Flip)';
  FChkMirror.Left    := 8;  FChkMirror.Top := 68; FChkMirror.Width := 280;
  FChkMirror.OnChange := @OnRotationChanged;

  FChkNegative := TCheckBox.Create(Self);
  FChkNegative.Parent  := ProcGrp;
  FChkNegative.Caption := 'Negative (Invert Colors)';
  FChkNegative.Left    := 8;  FChkNegative.Top := 106; FChkNegative.Width := 280;
  FChkNegative.OnChange := @OnRotationChanged;
  Inc(Y, 164);

  { ── Image Adjustment ── }
  AdjGrp := MakeGroupBox(Scroll, 'Gray Image Adjustment', 4, Y, 304, 454);
  MakeLabel(AdjGrp, 'Method:', 8, 20);
  FComboAdjustMethod := TComboBox.Create(Self);
  FComboAdjustMethod.Parent := AdjGrp;
  FComboAdjustMethod.Left := 80;
  FComboAdjustMethod.Top := 16;
  FComboAdjustMethod.Width := 216;
  FComboAdjustMethod.Style := csDropDownList;
  FComboAdjustMethod.Items.Add('Striplight current');
  FComboAdjustMethod.Items.Add('Quantum-like');
  FComboAdjustMethod.Items.Add('Original curve');
  FComboAdjustMethod.Items.Add('Gamma 1.2 curve');
  FComboAdjustMethod.Items.Add('Original curve + Quantum sliders');
  FComboAdjustMethod.ItemIndex := 0;
  FComboAdjustMethod.OnChange := @OnAdjustmentMethodChanged;

  MakeLabel(AdjGrp, 'Contrast:',    8, 48);
  FTrackContrast   := MakeTrack(AdjGrp, 80, 44, 154, -100, 100, 0);
  FTrackContrast.OnChange := @OnAdjustmentSliderChanged;
  FTrackContrast.OnMouseDown := @OnAdjustmentSliderMouseDown;
  FTrackContrast.OnMouseUp := @OnAdjustmentSliderRelease;
  FTrackContrast.OnKeyUp := @OnAdjustmentSliderKeyUp;
  FSpinContrast := TSpinEdit.Create(Self);
  FSpinContrast.Parent   := AdjGrp;
  FSpinContrast.Left     := 240; FSpinContrast.Top := 42;
  FSpinContrast.Width    := 52;
  FSpinContrast.MinValue := -100; FSpinContrast.MaxValue := 100;
  FSpinContrast.Value    := 0;
  FSpinContrast.OnChange := @OnAdjustmentSpinChanged;

  MakeLabel(AdjGrp, 'Brightness:',  8, 76);
  FTrackBrightness := MakeTrack(AdjGrp, 80, 72, 154, -100, 100, 0);
  FTrackBrightness.OnChange := @OnAdjustmentSliderChanged;
  FTrackBrightness.OnMouseDown := @OnAdjustmentSliderMouseDown;
  FTrackBrightness.OnMouseUp := @OnAdjustmentSliderRelease;
  FTrackBrightness.OnKeyUp := @OnAdjustmentSliderKeyUp;
  FSpinBrightness := TSpinEdit.Create(Self);
  FSpinBrightness.Parent   := AdjGrp;
  FSpinBrightness.Left     := 240; FSpinBrightness.Top := 70;
  FSpinBrightness.Width    := 52;
  FSpinBrightness.MinValue := -100; FSpinBrightness.MaxValue := 100;
  FSpinBrightness.Value    := 0;
  FSpinBrightness.OnChange := @OnAdjustmentSpinChanged;

  MakeLabel(AdjGrp, 'Gamma:',       8, 104);
  FTrackGamma      := MakeTrack(AdjGrp, 80, 100, 154, 10, 300, 100);
  FTrackGamma.OnChange := @OnAdjustmentSliderChanged;
  FTrackGamma.OnMouseDown := @OnAdjustmentSliderMouseDown;
  FTrackGamma.OnMouseUp := @OnAdjustmentSliderRelease;
  FTrackGamma.OnKeyUp := @OnAdjustmentSliderKeyUp;
  FSpinGamma := TSpinEdit.Create(Self);
  FSpinGamma.Parent   := AdjGrp;
  FSpinGamma.Left     := 240; FSpinGamma.Top := 98;
  FSpinGamma.Width    := 52;
  FSpinGamma.MinValue := 10; FSpinGamma.MaxValue := 300;
  FSpinGamma.Value    := 100;
  FSpinGamma.OnChange := @OnAdjustmentSpinChanged;

  MakeLabel(AdjGrp, 'JPEG Quality:', 8, 132);
  FSpinQuality := TSpinEdit.Create(Self);
  FSpinQuality.Parent   := AdjGrp;
  FSpinQuality.Left     := 90;  FSpinQuality.Top    := 128;
  FSpinQuality.Width    := 60;
  FSpinQuality.MinValue := 1;   FSpinQuality.MaxValue := 100;
  FSpinQuality.Value    := DEFAULT_JPG_QUALITY;
  FSpinQuality.OnChange := @OnExportNamingChanged;

  MakeButton(AdjGrp, 'Scan Defaults', 184, 128, 104, 24, @OnScanDefaults);

  FChkShadowLift := TCheckBox.Create(Self);
  FChkShadowLift.Parent := AdjGrp;
  FChkShadowLift.Caption := 'Shadow lift';
  FChkShadowLift.Left := 8;
  FChkShadowLift.Top := 160;
  FChkShadowLift.Width := 110;
  FChkShadowLift.OnChange := @OnAdjustmentOptionChanged;

  FChkHighlightRecovery := TCheckBox.Create(Self);
  FChkHighlightRecovery.Parent := AdjGrp;
  FChkHighlightRecovery.Caption := 'Highlight recovery';
  FChkHighlightRecovery.Left := 152;
  FChkHighlightRecovery.Top := 160;
  FChkHighlightRecovery.Width := 116;
  FChkHighlightRecovery.OnChange := @OnAdjustmentOptionChanged;

  FChkSCurveContrast := TCheckBox.Create(Self);
  FChkSCurveContrast.Parent := AdjGrp;
  FChkSCurveContrast.Caption := 'S-curve contrast';
  FChkSCurveContrast.Left := 8;
  FChkSCurveContrast.Top := 186;
  FChkSCurveContrast.Width := 116;
  FChkSCurveContrast.OnChange := @OnAdjustmentOptionChanged;

  FChkDocumentRescue := TCheckBox.Create(Self);
  FChkDocumentRescue.Parent := AdjGrp;
  FChkDocumentRescue.Caption := 'Document rescue';
  FChkDocumentRescue.Left := 152;
  FChkDocumentRescue.Top := 186;
  FChkDocumentRescue.Width := 116;
  FChkDocumentRescue.OnChange := @OnAdjustmentOptionChanged;

  FChkSoftContrast := TCheckBox.Create(Self);
  FChkSoftContrast.Parent := AdjGrp;
  FChkSoftContrast.Caption := 'Soft contrast';
  FChkSoftContrast.Left := 8;
  FChkSoftContrast.Top := 212;
  FChkSoftContrast.Width := 116;
  FChkSoftContrast.OnChange := @OnAdjustmentOptionChanged;

  MakeLabel(AdjGrp, 'Sharpness:', 8, 238);
  FTrackSharpness := MakeTrack(AdjGrp, 80, 234, 154, 0, 100, 0);
  FTrackSharpness.OnChange := @OnSharpnessChanged;
  FTrackSharpness.OnMouseDown := @OnAdjustmentSliderMouseDown;
  FTrackSharpness.OnMouseUp := @OnAdjustmentSliderRelease;
  FTrackSharpness.OnKeyUp := @OnAdjustmentSliderKeyUp;
  FSpinSharpness := TSpinEdit.Create(Self);
  FSpinSharpness.Parent := AdjGrp;
  FSpinSharpness.Left := 240;
  FSpinSharpness.Top := 232;
  FSpinSharpness.Width := 52;
  FSpinSharpness.MinValue := 0;
  FSpinSharpness.MaxValue := 100;
  FSpinSharpness.Value := 0;
  FSpinSharpness.OnChange := @OnSharpnessChanged;

  MakeLabel(AdjGrp, 'Sharp mode:', 8, 266);
  FComboSharpnessMode := TComboBox.Create(Self);
  FComboSharpnessMode.Parent := AdjGrp;
  FComboSharpnessMode.Left := 80;
  FComboSharpnessMode.Top := 262;
  FComboSharpnessMode.Width := 216;
  FComboSharpnessMode.Style := csDropDownList;
  FComboSharpnessMode.Items.Add('Soft');
  FComboSharpnessMode.Items.Add('Unsharp');
  FComboSharpnessMode.Items.Add('Text crisp');
  FComboSharpnessMode.Items.Add('High-pass');
  FComboSharpnessMode.ItemIndex := 0;
  FComboSharpnessMode.OnChange := @OnSharpnessModeChanged;

  FBtnAutoAdjustSelected := MakeButton(AdjGrp, 'Auto Adjust Selected', 8, 294, 280, 24, @OnAutoAdjustSelected);

  FLblSelectedAdjustment := MakeLabel(AdjGrp, 'Selected override: none', 8, 330);
  FLblSelectedAdjustment.Width := 280;
  FLblSelectedAdjustment.Height := 20;
  FLblSelectedAdjustment.AutoSize := False;

  FChkAdjustPreview := TCheckBox.Create(Self);
  FChkAdjustPreview.Parent   := AdjGrp;
  FChkAdjustPreview.Caption  := 'Apply adjustments to preview';
  FChkAdjustPreview.Left     := 8;
  FChkAdjustPreview.Top      := 354;
  FChkAdjustPreview.Width    := 280;
  FChkAdjustPreview.Checked  := False;
  FChkAdjustPreview.OnChange := @OnAdjustPreviewToggle;

  FBtnApplyPreview := MakeButton(AdjGrp, 'Apply Preview', 8, 382, 280, 24, @OnPreviewAdjustmentChanged);
  FBtnApplyPreview.Enabled := False;
  Inc(Y, 464);

  { ── Export Scope ── }
  ScopeGrp := MakeGroupBox(Scroll, 'Export Scope', 4, Y, 304, 92);
  FRbProcFull := TRadioButton.Create(Self);
  FRbProcFull.Parent  := ScopeGrp;
  FRbProcFull.Caption := 'Full Roll';
  FRbProcFull.Left    := 8;  FRbProcFull.Top := 18;
  FRbProcFull.Checked := True;
  FRbProcSelected := TRadioButton.Create(Self);
  FRbProcSelected.Parent  := ScopeGrp;
  FRbProcSelected.Caption := 'Selected Frames Only';
  FRbProcSelected.Left    := 8;  FRbProcSelected.Top := 42;
  Inc(Y, 102);

  { ── Export actions ── }
  ExportActionGrp := MakeGroupBox(Scroll, 'Export Actions', 4, Y, 304, 172);
  FBtnExportStart := MakeButton(ExportActionGrp, 'Start Export', 8, 20, 132, 28, @OnExportStart);
  FBtnExportPause := MakeButton(ExportActionGrp, 'Pause', 148, 20, 64, 28, @OnExportPause);
  FBtnExportPause.Enabled := False;
  FBtnExportStop  := MakeButton(ExportActionGrp, 'Stop', 220, 20, 68, 28, @OnExportStop);
  FBtnExportStop.Enabled := False;

  FBtnPrepareFolders := MakeButton(ExportActionGrp, 'Prepare Folders', 8, 56, 136, 25, @OnPrepareExportFolders);
  FBtnReExportFailed := MakeButton(ExportActionGrp, 'Re-export Failed', 152, 56, 136, 25, @OnReExportFailed);
  FBtnReExportFailed.Enabled := False;

  FProgressExport := TProgressBar.Create(Self);
  FProgressExport.Parent := ExportActionGrp;
  FProgressExport.Left   := 8;  FProgressExport.Top    := 92;
  FProgressExport.Width  := 280; FProgressExport.Height := 20;

  FLblExportStatus := MakeLabel(ExportActionGrp, 'Ready.', 8, 118);
  FLblExportStatus.AutoSize := False;
  FLblExportStatus.WordWrap := True;
  FLblExportStatus.Width := 280;
  FLblExportStatus.Height := 34;
  Inc(Y, 182);

  { ── Export settings ── }
  ExportSettingsGrp := MakeGroupBox(Scroll, 'Export Settings', 4, Y, 304, 288);

  FChkSkipExisting := TCheckBox.Create(Self);
  FChkSkipExisting.Parent  := ExportSettingsGrp;
  FChkSkipExisting.Caption := 'Skip existing files';
  FChkSkipExisting.Left    := 8;
  FChkSkipExisting.Top     := 20;
  FChkSkipExisting.Width   := 180;
  FChkSkipExisting.Checked := True;

  FChkAllowPreviewExport := TCheckBox.Create(Self);
  FChkAllowPreviewExport.Parent  := ExportSettingsGrp;
  FChkAllowPreviewExport.Caption := 'Allow preview fallback';
  FChkAllowPreviewExport.Left    := 8;
  FChkAllowPreviewExport.Top     := 44;
  FChkAllowPreviewExport.Width   := 190;
  FChkAllowPreviewExport.Checked := False;

  MakeLabel(ExportSettingsGrp, 'JPEG encoder:', 8, 74);
  FComboExportEncoder := TComboBox.Create(Self);
  FComboExportEncoder.Parent := ExportSettingsGrp;
  FComboExportEncoder.Left := 104;
  FComboExportEncoder.Top := 70;
  FComboExportEncoder.Width := 184;
  FComboExportEncoder.Style := csDropDownList;
  FComboExportEncoder.Items.Add('Built-in');
  FComboExportEncoder.Items.Add('TurboJPEG DLL');
  FComboExportEncoder.ItemIndex := EXPORT_ENCODER_BUILTIN;
  FComboExportEncoder.OnChange := @OnExportNamingChanged;

  FChkExportGrayscale := TCheckBox.Create(Self);
  FChkExportGrayscale.Parent  := ExportSettingsGrp;
  FChkExportGrayscale.Caption := 'Export grayscale JPEG';
  FChkExportGrayscale.Left    := 8;
  FChkExportGrayscale.Top     := 102;
  FChkExportGrayscale.Width   := 190;
  FChkExportGrayscale.Checked := True;
  FChkExportGrayscale.OnChange := @OnExportNamingChanged;

  FChkExportProgressive := TCheckBox.Create(Self);
  FChkExportProgressive.Parent  := ExportSettingsGrp;
  FChkExportProgressive.Caption := 'Progressive JPEG';
  FChkExportProgressive.Left    := 8;
  FChkExportProgressive.Top     := 126;
  FChkExportProgressive.Width   := 190;
  FChkExportProgressive.Checked := False;
  FChkExportProgressive.OnChange := @OnExportNamingChanged;

  FChkExportFollowPage := TCheckBox.Create(Self);
  FChkExportFollowPage.Parent  := ExportSettingsGrp;
  FChkExportFollowPage.Caption := 'Follow export page';
  FChkExportFollowPage.Left    := 8;
  FChkExportFollowPage.Top     := 150;
  FChkExportFollowPage.Width   := 190;
  FChkExportFollowPage.Checked := False;

  FChkExportBatchUI := TCheckBox.Create(Self);
  FChkExportBatchUI.Parent  := ExportSettingsGrp;
  FChkExportBatchUI.Caption := 'Batch export UI';
  FChkExportBatchUI.Left    := 8;
  FChkExportBatchUI.Top     := 174;
  FChkExportBatchUI.Width   := 190;
  FChkExportBatchUI.Checked := True;

  FChkExportLocalTemp := TCheckBox.Create(Self);
  FChkExportLocalTemp.Parent  := ExportSettingsGrp;
  FChkExportLocalTemp.Caption := 'Stage JPEGs locally';
  FChkExportLocalTemp.Left    := 8;
  FChkExportLocalTemp.Top     := 198;
  FChkExportLocalTemp.Width   := 190;
  FChkExportLocalTemp.Checked := False;

  FChkPrecreateFolders := TCheckBox.Create(Self);
  FChkPrecreateFolders.Parent  := ExportSettingsGrp;
  FChkPrecreateFolders.Caption := 'Pre-create folders on start';
  FChkPrecreateFolders.Left    := 8;
  FChkPrecreateFolders.Top     := 222;
  FChkPrecreateFolders.Width   := 220;
  FChkPrecreateFolders.Checked := False;

  FChkExportTiming := TCheckBox.Create(Self);
  FChkExportTiming.Parent  := ExportSettingsGrp;
  FChkExportTiming.Caption := 'Show export timing';
  FChkExportTiming.Left    := 8;
  FChkExportTiming.Top     := 246;
  FChkExportTiming.Width   := 190;
  FChkExportTiming.Checked := True;

  MakeLabel(ExportSettingsGrp, 'Cache:', 176, 106);
  FSpinExportCache := TSpinEdit.Create(Self);
  FSpinExportCache.Parent := ExportSettingsGrp;
  FSpinExportCache.Left := 232;
  FSpinExportCache.Top := 102;
  FSpinExportCache.Width := 56;
  FSpinExportCache.MinValue := 1;
  FSpinExportCache.MaxValue := 16;
  FSpinExportCache.Value := 4;

  MakeLabel(ExportSettingsGrp, 'Load:', 176, 134);
  FSpinExportLoadThreads := TSpinEdit.Create(Self);
  FSpinExportLoadThreads.Parent := ExportSettingsGrp;
  FSpinExportLoadThreads.Left := 232;
  FSpinExportLoadThreads.Top := 130;
  FSpinExportLoadThreads.Width := 56;
  FSpinExportLoadThreads.MinValue := 1;
  FSpinExportLoadThreads.MaxValue := 16;
  FSpinExportLoadThreads.Value := 4;

  MakeLabel(ExportSettingsGrp, 'Process:', 176, 162);
  FSpinExportProcessThreads := TSpinEdit.Create(Self);
  FSpinExportProcessThreads.Parent := ExportSettingsGrp;
  FSpinExportProcessThreads.Left := 232;
  FSpinExportProcessThreads.Top := 158;
  FSpinExportProcessThreads.Width := 56;
  FSpinExportProcessThreads.MinValue := 1;
  FSpinExportProcessThreads.MaxValue := 16;
  FSpinExportProcessThreads.Value := 4;
  Inc(Y, 298);
  Spacer := TPanel.Create(Self);
  Spacer.Parent := Scroll;
  Spacer.Left := 4;
  Spacer.Top := Y;
  Spacer.Width := 1;
  Spacer.Height := 1;
  Spacer.BevelOuter := bvNone;
end;

{ ============================================================ }
{ Files tab                                                     }
{ ============================================================ }

procedure TMainForm.BuildFilesTab;
var
  Y: Integer;
  Scroll: TScrollBox;
  ProjectGrp, NamingGrp, ArchiveGrp: TGroupBox;
  Spacer: TPanel;
begin
  Scroll := TScrollBox.Create(Self);
  Scroll.Parent      := FTabFiles;
  Scroll.Align       := alClient;
  Scroll.BorderStyle := bsNone;
  Scroll.AutoScroll  := True;
  ConfigureTabScrollBox(Scroll);
  Y := 8;

  ProjectGrp := MakeGroupBox(Scroll, 'Project Output', 8, Y, 316, 144);

  MakeLabel(ProjectGrp, 'Job Name:', 8, 22);
  FEdtJobName := TEdit.Create(Self);
  FEdtJobName.Parent := ProjectGrp;
  FEdtJobName.Left := 92;  FEdtJobName.Top   := 20;
  FEdtJobName.Width := 208;

  MakeLabel(ProjectGrp, 'Roll Name:', 8, 54);
  FEdtRollName := TEdit.Create(Self);
  FEdtRollName.Parent := ProjectGrp;
  FEdtRollName.Left := 92;  FEdtRollName.Top  := 50;
  FEdtRollName.Width := 208;

  MakeLabel(ProjectGrp, 'Output Dir:', 8, 88);
  FEdtOutputDir := TEdit.Create(Self);
  FEdtOutputDir.Parent := ProjectGrp;
  FEdtOutputDir.Left := 92;  FEdtOutputDir.Top   := 84;
  FEdtOutputDir.Width := 166;
  FEdtOutputDir.OnChange := @OnExportNamingChanged;
  FBtnBrowseOut := MakeButton(ProjectGrp, '...', 266, 84, 34, 22, @OnBrowseOutput);
  Inc(Y, 158);

  NamingGrp := MakeGroupBox(Scroll, 'Naming', 8, Y, 316, 204);

  MakeLabel(NamingGrp, 'Prefix:', 8, 22);
  FEdtPrefix := TEdit.Create(Self);
  FEdtPrefix.Parent := NamingGrp;
  FEdtPrefix.Left := 92;  FEdtPrefix.Top  := 20;
  FEdtPrefix.Width := 80;  FEdtPrefix.Text := 'gray';
  FEdtPrefix.OnChange := @OnExportNamingChanged;

  MakeLabel(NamingGrp, 'Digits:', 188, 24);
  FSpinFileDigits := TSpinEdit.Create(Self);
  FSpinFileDigits.Parent   := NamingGrp;
  FSpinFileDigits.Left     := 240;  FSpinFileDigits.Top     := 20;
  FSpinFileDigits.Width    := 60;  FSpinFileDigits.Value   := 5;
  FSpinFileDigits.MinValue := 1;   FSpinFileDigits.MaxValue := 9;
  FSpinFileDigits.OnChange := @OnExportNamingChanged;

  MakeLabel(NamingGrp, 'Start #:', 8, 58);
  FSpinStartNum := TSpinEdit.Create(Self);
  FSpinStartNum.Parent   := NamingGrp;
  FSpinStartNum.Left     := 92;  FSpinStartNum.Top      := 54;
  FSpinStartNum.Width    := 60;  FSpinStartNum.Value    := 1;
  FSpinStartNum.MinValue := 0;   FSpinStartNum.MaxValue := 999999;
  FSpinStartNum.OnChange := @OnExportNamingChanged;

  FChkSepFolders := TCheckBox.Create(Self);
  FChkSepFolders.Parent  := NamingGrp;
  FChkSepFolders.Caption := 'Separate Folders (markers)';
  FChkSepFolders.Left    := 8;  FChkSepFolders.Top     := 90;
  FChkSepFolders.Width   := 220;
  FChkSepFolders.Checked := True;
  FChkSepFolders.OnChange := @OnExportNamingChanged;

  FChkReverseOrder := TCheckBox.Create(Self);
  FChkReverseOrder.Parent  := NamingGrp;
  FChkReverseOrder.Caption := 'Reverse Order';
  FChkReverseOrder.Left    := 8;  FChkReverseOrder.Top  := 116;
  FChkReverseOrder.Width   := 180;
  FChkReverseOrder.OnChange := @OnExportNamingChanged;

  MakeLabel(NamingGrp, 'Mode:', 8, 150);
  FComboExportNaming := TComboBox.Create(Self);
  FComboExportNaming.Parent := NamingGrp;
  FComboExportNaming.Left := 92;
  FComboExportNaming.Top := 146;
  FComboExportNaming.Width := 208;
  FComboExportNaming.Style := csDropDownList;
  FComboExportNaming.Items.Add('Quantum folders');
  FComboExportNaming.Items.Add('Archive list');
  FComboExportNaming.ItemIndex := 0;
  FComboExportNaming.OnChange := @OnExportNamingChanged;
  Inc(Y, 218);

  ArchiveGrp := MakeGroupBox(Scroll, 'Archive List', 8, Y, 316, 272);
  FMemoArchiveList := TMemo.Create(Self);
  FMemoArchiveList.Parent := ArchiveGrp;
  FMemoArchiveList.Left := 8;
  FMemoArchiveList.Top := 20;
  FMemoArchiveList.Width := 292;
  FMemoArchiveList.Height := 116;
  FMemoArchiveList.ScrollBars := ssVertical;
  FMemoArchiveList.WordWrap := False;
  FMemoArchiveList.HideSelection := False;
  FMemoArchiveList.OnChange := @OnArchiveListChanged;

  MakeButton(ArchiveGrp, 'Build from Folders...', 8, 142, 292, 25,
    @OnBuildArchiveListFromFolders).Hint :=
    'Choose a root folder and create one archive-list row for each leaf folder';

  FLblExportPreview := MakeLabel(ArchiveGrp, 'Export preview: no frame selected', 8, 180);
  FLblExportPreview.Width := 292;
  FLblExportPreview.Height := 72;
  FLblExportPreview.AutoSize := False;
  FLblExportPreview.WordWrap := True;
  Inc(Y, 286);

  Spacer := TPanel.Create(Self);
  Spacer.Parent := Scroll;
  Spacer.Left := 4;
  Spacer.Top := Y;
  Spacer.Width := 1;
  Spacer.Height := 1;
  Spacer.BevelOuter := bvNone;
end;

{ ============================================================ }
{ Status bar                                                    }
{ ============================================================ }

procedure TMainForm.BuildStatusBar;
begin
  FStatusBar := TStatusBar.Create(Self);
  FStatusBar.Parent      := Self;
  FStatusBar.Align       := alBottom;
  FStatusBar.SimplePanel := False;

  with FStatusBar.Panels do
  begin
    Add.Width := 130;  // Page x of y
    Add.Width := 170;  // Frames / markers
    Add.Width := 130;  // Selected / Suggested
    Add.Width := 200;  // Roll: name
    Add.Width := 520;  // Current preview file / folder position
  end;
end;

{ ============================================================ }
{ Event handlers                                                }
{ ============================================================ }

procedure TMainForm.OnOpenIDF(Sender: TObject);
begin
  OnOpen(Sender);
end;

procedure TMainForm.OnOpen(Sender: TObject);
var
  Dlg: TOpenDialog;
  Ext: String;
begin
  Dlg := TOpenDialog.Create(Self);
  try
    Dlg.Title   := 'Open File';
    Dlg.Filter  := 'Project and IDF Files (*.idf;*.xml;*.slf;*.qpf)|*.idf;*.xml;*.slf;*.qpf|IDF Files (*.idf;*.xml)|*.idf;*.xml|Striplight Files (*.slf)|*.slf|QPF Files (*.qpf)|*.qpf|All Files (*.*)|*.*';
    Dlg.Options := Dlg.Options + [ofFileMustExist];
    if not Dlg.Execute then Exit;

    Ext := LowerCase(ExtractFileExt(Dlg.FileName));
    if (Ext = '.idf') or (Ext = '.xml') then
      OpenIDFFile(Dlg.FileName)
    else if (Ext = '.slf') or (Ext = '.qpf') then
      OpenProjectFile(Dlg.FileName)
    else
      ShowMessage('Unsupported file type: ' + Ext);
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.OpenIDFFile(const FileName: String);
var
  ParseResult: TIDFParseResult;
  Msg: String;
begin
  StopBackgroundCache(False);
  ParseResult := ParseIDF(FileName, FRollData, FFrames);
  if ParseResult <> iprOK then
  begin
    MessageDlg('Could not load IDF',
               'Error: ' + IDFResultMessage(ParseResult),
               mtError, [mbOK], 0);
    Exit;
  end;

  FCurrentIDFPath := FileName;
  FCurrentProjectPath := '';
  if Assigned(FChkCachePreviews) and FChkCachePreviews.Checked then
    PreparePreviewCacheForRoll;

  Msg := Format('Loaded IDF "%s"'#13#10'Strips: %d  |  Frames: %d',
                [FRollData.RollName, FRollData.StripCount, Length(FFrames)]);
  if FRollData.PreviewCacheEnabled then
    Msg := Msg + #13#10 + 'Preview cache is on: missing previews will be cached during detection.';

  SetAppTitle(ExtractFileName(FCurrentIDFPath));

  CalculateFrameStats(FFrames, FFrameStats);
  FStripView.LoadRoll(FRollData, FFrames);
  RefreshFrameColors;
  UpdateFilesTab;
  FEdtRangeFrom.MaxValue := Max(1, FRollData.StripCount);
  FEdtRangeTo.MaxValue   := Max(1, FRollData.StripCount);
  FEdtRangeFrom.Value    := 1;
  FEdtRangeTo.Value      := Max(1, FRollData.StripCount);
  FSpinMinW.Value        := Max(FSpinMinW.MinValue, Min(FSpinMinW.MaxValue, FRollData.DetectMinWidth));
  FSpinMinH.Value        := Max(FSpinMinH.MinValue, Min(FSpinMinH.MaxValue, FRollData.DetectMinLength));
  OnScanDefaults(Self);
  SyncDetectRangeToView;
  ClearFrameUndo;
  FDirty := False;
  UpdateNavButtons;
  UpdateStatus;
  ShowMessage(Msg);
end;

procedure TMainForm.OpenProjectFile(const FileName: String);
begin
  LoadProjectFile(FileName);
end;

procedure TMainForm.OnOpenQPF(Sender: TObject);
begin
  OnOpen(Sender);
end;

procedure TMainForm.OnOpenSLF(Sender: TObject);
begin
  OnOpen(Sender);
end;

procedure TMainForm.OnSave(Sender: TObject);
begin
  if not FRollData.Loaded then Exit;
  if FCurrentProjectPath = '' then
    PromptSaveSLFAs
  else
  begin
    SaveSLFToFile(FCurrentProjectPath, True);
    SetAppTitle(ExtractFileName(FCurrentProjectPath));
  end;
end;

procedure TMainForm.OnSaveAs(Sender: TObject);
begin
  PromptSaveSLFAs;
end;

procedure TMainForm.OnSaveQPFAs(Sender: TObject);
begin
  PromptSaveQPFAs;
end;

procedure TMainForm.OnFirst(Sender: TObject);  begin FStripView.GotoFirst; end;
procedure TMainForm.OnPrev(Sender: TObject);   begin FStripView.GotoPrev;  end;
procedure TMainForm.OnNext(Sender: TObject);   begin FStripView.GotoNext;  end;
procedure TMainForm.OnLast(Sender: TObject);   begin FStripView.GotoLast;  end;

procedure TMainForm.OnStripsChanged(Sender: TObject);
var
  Count, ZoomPct: Integer;
begin
  if FAutoLayoutUpdating then
  begin
    FStripView.StripsPerRow := FSpinStrips.Value;
    UpdateNavButtons;
    UpdateStatus;
    Exit;
  end;

  if FChkAutoStrips.Checked then
  begin
    Count := Max(FSpinStrips.MinValue, Min(FSpinStrips.MaxValue, FSpinStrips.Value));
    ZoomPct := Max(FTrackZoom.Min, Min(FTrackZoom.Max,
      Round(FStripView.ClientWidth / Max(1, Count) / 160.0 * 100.0)));
    FAutoLayoutUpdating := True;
    try
      ApplyZoomPercent(ZoomPct);
      FStripView.StripsPerRow := Count;
    finally
      FAutoLayoutUpdating := False;
    end;
    UpdateNavButtons;
    UpdateStatus;
    Exit;
  end;

  FStripView.StripsPerRow := FSpinStrips.Value;
  UpdateNavButtons;
  UpdateStatus;
end;

procedure TMainForm.OnZoomChanged(Sender: TObject);
begin
  if FApplyingZoom then Exit;
  ApplyZoomPercent(FTrackZoom.Position);
  if FChkAutoStrips.Checked then DoAutoStrips;
end;

procedure TMainForm.OnCachePreviewsToggle(Sender: TObject);
begin
  if not FRollData.Loaded then Exit;

  if FChkCachePreviews.Checked then
  begin
    PreparePreviewCacheForRoll;
    FStripView.LoadRoll(FRollData, FFrames);
    UpdateStatus;
  end
  else
  begin
    FRollData.PreviewCacheEnabled := False;
    if FRollData.PreviewSourceBasePath <> '' then
      FRollData.PreviewBasePath := FRollData.PreviewSourceBasePath
    else
      FRollData.PreviewBasePath := FRollData.BasePath;
    if FRollData.PreviewSourceFolder <> '' then
      FRollData.PreviewFolder := FRollData.PreviewSourceFolder;
    FLblDetectStatus.Caption := 'Preview cache off; using original preview folder.';
    FStripView.LoadRoll(FRollData, FFrames);
    UpdateStatus;
  end;
end;

procedure TMainForm.OnClearPreviewCaches(Sender: TObject);
begin
  if Assigned(FBgCacheThread) then
  begin
    StopBackgroundCache(False);
    FLblDetectStatus.Caption := 'Stopping background cache. Press Clear Caches again after it stops.';
    Exit;
  end;

  if MessageDlg('Delete ALL local preview cache folders?',
                mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  if Assigned(FChkCachePreviews) then
    FChkCachePreviews.Checked := False;
  if FRollData.Loaded then
  begin
    FRollData.PreviewCacheEnabled := False;
    if FRollData.PreviewSourceBasePath <> '' then
      FRollData.PreviewBasePath := FRollData.PreviewSourceBasePath
    else
      FRollData.PreviewBasePath := FRollData.BasePath;
    if FRollData.PreviewSourceFolder <> '' then
      FRollData.PreviewFolder := FRollData.PreviewSourceFolder;
    FStripView.LoadRoll(FRollData, FFrames);
  end;

  PurgeAllPreviewCaches;
  FLblDetectStatus.Caption := 'All local preview caches cleared.';
  UpdateStatus;
end;

procedure TMainForm.OnBackgroundCache(Sender: TObject);
var
  WorkerRoll: TRollData;
begin
  if Assigned(FBgCacheThread) then
  begin
    StopBackgroundCache(False);
    FLblDetectStatus.Caption := 'Stopping background preview cache...';
    Exit;
  end;

  if not FRollData.Loaded then
  begin
    ShowMessage('Load an IDF first, then start background caching.');
    Exit;
  end;

  WorkerRoll := FRollData;
  if WorkerRoll.PreviewSourceBasePath = '' then
    WorkerRoll.PreviewSourceBasePath := WorkerRoll.BasePath;
  if WorkerRoll.PreviewSourceFolder = '' then
    WorkerRoll.PreviewSourceFolder := WorkerRoll.PreviewFolder;
  WorkerRoll.PreviewBasePath := IncludeTrailingPathDelimiter(PreviewCacheProjectRoot);
  WorkerRoll.PreviewFolder := 'previews';
  WorkerRoll.PreviewCacheEnabled := True;
  ForceDirectories(IncludeTrailingPathDelimiter(WorkerRoll.PreviewBasePath) + WorkerRoll.PreviewFolder);

  FBgCacheQueueMode := False;
  FBgCacheThread := TPreviewCacheThread.Create(Self, WorkerRoll);
  SetSpeedButtonAction(FBtnBgCache, 'Stop Cache');
  FLblDetectStatus.Caption := 'Background preview cache started.';
end;

procedure TMainForm.OnCacheManager(Sender: TObject);
var
  Btn: TBitBtn;
  TopPanel, ActionPanel, QueuePanel, BottomPanel: TPanel;
begin
  if Assigned(FCacheMgrForm) then
  begin
    FCacheMgrForm.Show;
    FCacheMgrForm.BringToFront;
    Exit;
  end;

  FCacheMgrForm := TForm.Create(Self);
  FCacheMgrForm.Caption := 'Preview Cache Manager';
  FCacheMgrForm.Position := poMainFormCenter;
  FCacheMgrForm.Width := 900;
  FCacheMgrForm.Height := 660;
  FCacheMgrForm.OnClose := @OnCacheMgrClose;

  TopPanel := TPanel.Create(FCacheMgrForm);
  TopPanel.Parent := FCacheMgrForm;
  TopPanel.Align := alTop;
  TopPanel.Height := 190;
  TopPanel.BevelOuter := bvNone;
  TopPanel.BorderSpacing.Around := 8;

  ActionPanel := TPanel.Create(FCacheMgrForm);
  ActionPanel.Parent := TopPanel;
  ActionPanel.Align := alRight;
  ActionPanel.Width := 170;
  ActionPanel.BevelOuter := bvNone;

  FCacheMemo := TMemo.Create(FCacheMgrForm);
  FCacheMemo.Parent := TopPanel;
  FCacheMemo.Align := alClient;
  FCacheMemo.BorderSpacing.Right := 8;
  FCacheMemo.ScrollBars := ssBoth;
  FCacheMemo.WordWrap := False;

  FBtnCacheMgrAddPaths := MakeButton(ActionPanel, 'Add Paths', 8, 0, 150, 28, @OnCacheMgrAddPaths);
  FBtnCacheMgrAddPaths.Hint := 'Add pasted IDF paths or folders from the text box';
  FBtnCacheMgrAddPaths.ShowHint := True;
  FBtnCacheMgrAddFolder := MakeButton(ActionPanel, 'Add Folder...', 8, 34, 150, 28, @OnCacheMgrAddFolder);
  FBtnCacheMgrAddFolder.Hint := 'Scan a folder recursively for IDF/XML projects';
  FBtnCacheMgrAddFolder.ShowHint := True;
  FBtnCacheMgrRemove := MakeButton(ActionPanel, 'Remove Selected', 8, 72, 150, 28, @OnCacheMgrRemove);
  FBtnCacheMgrRefresh := MakeButton(ActionPanel, 'Refresh List', 8, 106, 150, 28, @OnCacheMgrRefresh);

  FBtnCacheMgrStart := MakeButton(ActionPanel, 'Start Queue', 8, 146, 72, 28, @OnCacheMgrStart);
  FBtnCacheMgrStop := MakeButton(ActionPanel, 'Stop', 86, 146, 72, 28, @OnCacheMgrStop);
  FBtnCacheMgrStop.Enabled := False;

  BottomPanel := TPanel.Create(FCacheMgrForm);
  BottomPanel.Parent := FCacheMgrForm;
  BottomPanel.Align := alBottom;
  BottomPanel.Height := 34;
  BottomPanel.BevelOuter := bvNone;
  BottomPanel.BorderSpacing.Around := 8;
  FCacheMgrStatus := MakeLabel(BottomPanel, 'Ready.', 0, 8);

  QueuePanel := TPanel.Create(FCacheMgrForm);
  QueuePanel.Parent := FCacheMgrForm;
  QueuePanel.Align := alClient;
  QueuePanel.BevelOuter := bvNone;
  QueuePanel.BorderSpacing.Left := 8;
  QueuePanel.BorderSpacing.Right := 8;
  QueuePanel.BorderSpacing.Bottom := 0;
  FCacheList := TListBox.Create(FCacheMgrForm);
  FCacheList.Parent := QueuePanel;
  FCacheList.Align := alClient;
  FCacheList.MultiSelect := True;
  FCacheList.ScrollWidth := 1200;

  RefreshCacheQueueList;
  FCacheMgrForm.Show;
end;

procedure TMainForm.OnCacheMgrAddPaths(Sender: TObject);
var
  i: Integer;
  Roots: TStringList;
begin
  if not Assigned(FCacheMemo) then Exit;
  if Assigned(FCacheScanThread) then Exit;

  Roots := TStringList.Create;
  try
    for i := 0 to FCacheMemo.Lines.Count - 1 do
      if Trim(FCacheMemo.Lines[i]) <> '' then
        Roots.Add(Trim(FCacheMemo.Lines[i]));
    if Roots.Count = 0 then Exit;
    FCacheScanThread := TCacheScanThread.Create(Self, Roots);
    if Assigned(FBtnCacheMgrAddPaths) then FBtnCacheMgrAddPaths.Enabled := False;
    if Assigned(FBtnCacheMgrAddFolder) then FBtnCacheMgrAddFolder.Enabled := False;
    if Assigned(FCacheMgrStatus) then FCacheMgrStatus.Caption := 'Scanning pasted paths...';
  finally
    Roots.Free;
  end;
end;

procedure TMainForm.OnCacheMgrAddFolder(Sender: TObject);
var
  Dir: String;
  Roots: TStringList;
begin
  Dir := '';
  if SelectDirectory('Select project root folder', '', Dir) then
  begin
    if Assigned(FCacheScanThread) then Exit;
    Roots := TStringList.Create;
    try
      Roots.Add(Dir);
      FCacheScanThread := TCacheScanThread.Create(Self, Roots);
      if Assigned(FBtnCacheMgrAddPaths) then FBtnCacheMgrAddPaths.Enabled := False;
      if Assigned(FBtnCacheMgrAddFolder) then FBtnCacheMgrAddFolder.Enabled := False;
      if Assigned(FCacheMgrStatus) then FCacheMgrStatus.Caption := 'Scanning folder...';
    finally
      Roots.Free;
    end;
  end;
end;

procedure TMainForm.OnCacheMgrRemove(Sender: TObject);
var
  i: Integer;
begin
  if FCacheQueueRunning then Exit;
  if not Assigned(FCacheList) then Exit;
  for i := FCacheList.Items.Count - 1 downto 0 do
    if FCacheList.Selected[i] then
      FCacheQueuePaths.Delete(i);
  SaveCacheQueue;
  RefreshCacheQueueList;
end;

procedure TMainForm.OnCacheMgrStart(Sender: TObject);
begin
  if FCacheQueuePaths.Count = 0 then
  begin
    ShowMessage('Add at least one project path first.');
    Exit;
  end;
  if Assigned(FBgCacheThread) then
  begin
    ShowMessage('A cache job is already running.');
    Exit;
  end;
  FCacheQueueRunning := True;
  FCacheQueueStopRequested := False;
  FCacheQueueIndex := 0;
  FBgCacheQueueMode := True;
  if Assigned(FBtnCacheMgrStart) then FBtnCacheMgrStart.Enabled := False;
  if Assigned(FBtnCacheMgrStop) then FBtnCacheMgrStop.Enabled := True;
  RefreshCacheQueueList;
  StartNextCacheQueueItem;
end;

procedure TMainForm.OnCacheMgrStop(Sender: TObject);
begin
  FCacheQueueStopRequested := True;
  StopBackgroundCache(False);
  if Assigned(FCacheMgrStatus) then
    FCacheMgrStatus.Caption := 'Stopping queue after current file...';
end;

procedure TMainForm.OnCacheMgrRefresh(Sender: TObject);
begin
  RefreshCacheQueueList(True);
end;

procedure TMainForm.OnCacheMgrClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  SaveCacheQueue;
  StopCacheScan(False);
  FCacheMgrForm := nil;
  FCacheMemo := nil;
  FCacheList := nil;
  FCacheMgrStatus := nil;
  FBtnCacheMgrStart := nil;
  FBtnCacheMgrStop := nil;
  CloseAction := caFree;
end;

procedure TMainForm.OnStripsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    OnStripsChanged(Self);
    Key := 0;
  end;
end;

procedure TMainForm.OnZoomKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    ApplyZoomPercent(FSpinZoom.Value);
    if FChkAutoStrips.Checked then DoAutoStrips;
    Key := 0;
  end;
end;

procedure TMainForm.OnPageJumpKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_RETURN then
  begin
    if FRollData.Loaded then
      FStripView.GotoPage(FSpinPageJump.Value - 1);
    Key := 0;
  end;
end;

procedure TMainForm.OnTabScrollMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  Scroll: TScrollBox;
  Step: Integer;
begin
  if not (Sender is TScrollBox) then Exit;
  Scroll := TScrollBox(Sender);
  Step := Max(96, Scroll.ClientHeight div 3);
  if ssShift in Shift then
  begin
    if WheelDelta < 0 then
      Scroll.HorzScrollBar.Position := Scroll.HorzScrollBar.Position + Step
    else
      Scroll.HorzScrollBar.Position := Max(0, Scroll.HorzScrollBar.Position - Step);
  end
  else
  begin
    if WheelDelta < 0 then
      Scroll.VertScrollBar.Position := Scroll.VertScrollBar.Position + Step
    else
      Scroll.VertScrollBar.Position := Max(0, Scroll.VertScrollBar.Position - Step);
  end;
  Handled := True;
end;

procedure TMainForm.OnPageChanged(Sender: TObject);
begin
  UpdateNavButtons;
  UpdateStatus;
end;

procedure TMainForm.OnSelectionChanged(Sender: TObject);
var
  FrameIdx: Integer;
begin
  if FRollData.Loaded and Assigned(FStripView) then
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  UpdateSelectedAdjustmentStatus;
  UpdateStatus;
  if Assigned(FPreviewForm) then
  begin
    FrameIdx := GetSingleSelectedFrameIdx;
    if (FrameIdx >= 0) and (FrameIdx <> FPreviewFrameIdx) then
      PreviewSelectFrame(FrameIdx);
  end;
end;

procedure TMainForm.OnExportMarkChanged(Sender: TObject);
begin
  if FRollData.Loaded and Assigned(FStripView) then
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  UpdateStatus;
end;

procedure TMainForm.OnDeleteFrameSection(Sender: TObject);
begin
  if not Assigned(FStripView) then Exit;
  DeleteMarkerFrameSection(FStripView.ContextFrame);
end;

procedure TMainForm.OnSelectFrameSection(Sender: TObject);
begin
  if not Assigned(FStripView) then Exit;
  SelectMarkerFrameSection(FStripView.ContextFrame);
end;

procedure TMainForm.OnFrameDblClick(Sender: TObject);
var
  FrameIdx: Integer;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  FrameIdx := GetSingleSelectedFrameIdx;
  if FrameIdx < 0 then
  begin
    ShowMessage('Select one frame, then preview it.');
    Exit;
  end;

  ShowFramePreview(FrameIdx);
end;

function TMainForm.CurrentProcessRotation: Integer;
begin
  if FRbRotM90.Checked then Result := 270
  else if FRbRot90.Checked then Result := 90
  else if FRbRot180.Checked then Result := 180
  else Result := 0;
end;

function TMainForm.CurrentAdjustmentFlags: Integer;
begin
  Result := 0;
  if Assigned(FChkShadowLift) and FChkShadowLift.Checked then
    Result := Result or ADJ_FLAG_SHADOW_LIFT;
  if Assigned(FChkHighlightRecovery) and FChkHighlightRecovery.Checked then
    Result := Result or ADJ_FLAG_HIGHLIGHT_RECOVERY;
  if Assigned(FChkSCurveContrast) and FChkSCurveContrast.Checked then
    Result := Result or ADJ_FLAG_S_CURVE;
  if Assigned(FChkDocumentRescue) and FChkDocumentRescue.Checked then
    Result := Result or ADJ_FLAG_DOCUMENT_RESCUE;
  if Assigned(FChkSoftContrast) and FChkSoftContrast.Checked then
    Result := Result or ADJ_FLAG_SOFT_CONTRAST;
end;

function TMainForm.ProjectFramesFolder: String;
var
  Root: String;
begin
  if FCurrentProjectPath <> '' then
    Root := ExtractFilePath(FCurrentProjectPath)
  else if FCurrentIDFPath <> '' then
    Root := ExtractFilePath(FCurrentIDFPath)
  else
    Root := FRollData.BasePath;
  Result := IncludeTrailingPathDelimiter(Root) + 'frames';
end;

function TMainForm.ArchiveListLineIndexForFrame(FrameIdx: Integer): Integer;
var
  i, VolumeNo, RowNo: Integer;
  CleanLine: String;
begin
  Result := -1;
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;
  if not Assigned(FMemoArchiveList) then Exit;

  VolumeNo := 0;
  for i := 0 to FrameIdx do
    if FFrames[i].IsMarker then
      Inc(VolumeNo);
  if VolumeNo = 0 then
    VolumeNo := 1;

  RowNo := 0;
  for i := 0 to FMemoArchiveList.Lines.Count - 1 do
  begin
    CleanLine := Trim(FMemoArchiveList.Lines[i]);
    if CleanLine = '' then Continue;
    Inc(RowNo);
    if RowNo = VolumeNo then
      Exit(i);
  end;
end;

procedure TMainForm.HighlightArchiveListLineForFrame(FrameIdx: Integer);
var
  LineIdx, i, StartPos, LineLen: Integer;
begin
  if not Assigned(FMemoArchiveList) then Exit;
  if FMemoArchiveList.Focused then Exit;

  LineIdx := ArchiveListLineIndexForFrame(FrameIdx);
  if LineIdx < 0 then
  begin
    FMemoArchiveList.SelLength := 0;
    Exit;
  end;

  StartPos := 0;
  for i := 0 to LineIdx - 1 do
    Inc(StartPos, Length(FMemoArchiveList.Lines[i]) + Length(LineEnding));
  LineLen := Length(FMemoArchiveList.Lines[LineIdx]);
  FMemoArchiveList.SelStart := StartPos;
  FMemoArchiveList.SelLength := LineLen;
end;

function TMainForm.ExportPathForFrame(FrameIdx: Integer; out FolderPath, FileName,
  FullPath, Err: String): Boolean;
var
  i, VolumeNo, VolumeStart, FileNo, ListCount: Integer;
  OutputRoot, LineText, CleanLine, Prefix: String;
  Parts: TStringList;
  UseArchiveNaming, SepFolders: Boolean;

  function IsExportMarker(Idx: Integer): Boolean;
  begin
    Result := (Idx >= 0) and (Idx <= High(FFrames)) and FFrames[Idx].IsMarker;
  end;

begin
  Result := False;
  FolderPath := '';
  FileName := '';
  FullPath := '';
  Err := '';
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then
  begin
    Err := 'Frame index out of range.';
    Exit;
  end;

  OutputRoot := FEdtOutputDir.Text;
  if OutputRoot = '' then
    OutputRoot := ProjectFramesFolder;

  VolumeNo := 0;
  VolumeStart := 0;
  for i := 0 to FrameIdx do
    if IsExportMarker(i) then
    begin
      Inc(VolumeNo);
      VolumeStart := i;
    end;
  if VolumeNo = 0 then
    VolumeNo := 1;
  FileNo := Max(1, FrameIdx - VolumeStart + 1);

  UseArchiveNaming := False;
  if Assigned(FComboExportNaming) then
    UseArchiveNaming := FComboExportNaming.ItemIndex = 1;

  if UseArchiveNaming then
  begin
    ListCount := 0;
    LineText := '';
    if Assigned(FMemoArchiveList) then
      for i := 0 to FMemoArchiveList.Lines.Count - 1 do
      begin
        CleanLine := Trim(FMemoArchiveList.Lines[i]);
        if CleanLine = '' then Continue;
        Inc(ListCount);
        if ListCount = VolumeNo then
          LineText := CleanLine;
      end;
    if LineText = '' then
    begin
      Err := Format('Missing archive list row for volume %d.', [VolumeNo]);
      Exit;
    end;

    Parts := TStringList.Create;
    try
      CleanLine := LineText;
      while CleanLine <> '' do
      begin
        if CleanLine[1] <> ';' then Break;
        Delete(CleanLine, 1, 1);
      end;
      Parts.StrictDelimiter := True;
      Parts.Delimiter := ';';
      Parts.DelimitedText := CleanLine;
      FolderPath := OutputRoot;
      Prefix := '';
      for i := 0 to Parts.Count - 1 do
      begin
        if Trim(Parts[i]) = '' then Continue;
        FolderPath := IncludeTrailingPathDelimiter(FolderPath) + Trim(Parts[i]);
        if Prefix <> '' then Prefix := Prefix + '_';
        Prefix := Prefix + Trim(Parts[i]);
      end;
      if Prefix = '' then
        Prefix := 'archive';
      FileName := Prefix + '_' + ZeroPadInt(FileNo, FSpinFileDigits.Value) + '.jpg';
    finally
      Parts.Free;
    end;
  end
  else
  begin
    SepFolders := True;
    if Assigned(FChkSepFolders) then
      SepFolders := FChkSepFolders.Checked;
    if SepFolders then
      FolderPath := IncludeTrailingPathDelimiter(OutputRoot) +
                    ZeroPadInt(VolumeNo, FSpinFileDigits.Value)
    else
      FolderPath := OutputRoot;
    FileName := FEdtPrefix.Text + ZeroPadInt(FileNo, FSpinFileDigits.Value) + '.jpg';
  end;

  FullPath := IncludeTrailingPathDelimiter(FolderPath) + FileName;
  Result := True;
end;

procedure TMainForm.DeleteMarkerFrameSection(FrameIdx: Integer);
var
  StartIdx, EndIdx, DeleteCount, i, j: Integer;
  NewFrames: TFrameList;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  StartIdx := -1;
  for i := FrameIdx downto 0 do
    if FFrames[i].IsMarker then
    begin
      StartIdx := i;
      Break;
    end;

  if StartIdx < 0 then
  begin
    ShowMessage('No yellow marker found before this frame.');
    Exit;
  end;

  EndIdx := High(FFrames);
  for i := StartIdx + 1 to High(FFrames) do
    if FFrames[i].IsMarker then
    begin
      EndIdx := i - 1;
      Break;
    end;

  DeleteCount := EndIdx - StartIdx + 1;
  if DeleteCount <= 0 then Exit;
  if MessageDlg(Format('Delete %d frame(s) from frame %d to %d?'#13#10 +
     'The starting yellow marker is included. The next yellow marker will be left alone.'#13#10 +
     'Exported JPG files on disk will not be deleted.',
     [DeleteCount, StartIdx + 1, EndIdx + 1]),
     mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  PushFrameUndo;
  SetLength(NewFrames, Length(FFrames) - DeleteCount);
  j := 0;
  for i := 0 to High(FFrames) do
  begin
    if (i >= StartIdx) and (i <= EndIdx) then Continue;
    NewFrames[j] := FFrames[i];
    NewFrames[j].Index := j;
    Inc(j);
  end;

  FFrames := NewFrames;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  if Assigned(FPreviewForm) then
    FPreviewForm.Close;
end;

procedure TMainForm.SelectMarkerFrameSection(FrameIdx: Integer);
var
  StartIdx, EndIdx, SelectCount, i: Integer;

  function IsSectionMarker(Idx: Integer): Boolean;
  begin
    Result := (Idx >= 0) and (Idx <= High(FFrames)) and
              (FFrames[Idx].IsMarker or FFrames[Idx].IsSuggested);
  end;

begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  StartIdx := -1;
  for i := FrameIdx downto 0 do
    if IsSectionMarker(i) then
    begin
      StartIdx := i;
      Break;
    end;

  if StartIdx < 0 then
  begin
    ShowMessage('No yellow or suggested marker found before this frame.');
    Exit;
  end;

  EndIdx := High(FFrames);
  for i := StartIdx + 1 to High(FFrames) do
    if IsSectionMarker(i) then
    begin
      EndIdx := i - 1;
      Break;
    end;

  SelectCount := EndIdx - StartIdx + 1;
  if SelectCount <= 0 then Exit;
  for i := 0 to High(FFrames) do
    FFrames[i].IsSelected := (i >= StartIdx) and (i <= EndIdx);

  FStripView.UpdateFrames(FFrames);
  UpdateSelectedAdjustmentStatus;
  UpdateStatus;
  FStatusBar.SimpleText := Format('Selected %d frame(s) from section %d-%d.',
                                  [SelectCount, StartIdx + 1, EndIdx + 1]);
end;

function TMainForm.ExportNamingPreviewForFrame(FrameIdx: Integer;
  IncludeOutputRoot: Boolean): String;
var
  i, VolumeNo, VolumeStart, VolumeEnd, FileNo, MarkerCount, ListCount: Integer;
  OutputRoot, FolderName, FolderPath, FileName, LineText, CleanLine, Prefix: String;
  UseArchiveNaming: Boolean;
  Parts: TStringList;

  function IsExportMarker(Idx: Integer): Boolean;
  begin
    Result := (Idx >= 0) and (Idx <= High(FFrames)) and FFrames[Idx].IsMarker;
  end;

begin
  Result := '';
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  OutputRoot := FEdtOutputDir.Text;
  if OutputRoot = '' then
    OutputRoot := ProjectFramesFolder;
  UseArchiveNaming := False;
  if Assigned(FComboExportNaming) then
    UseArchiveNaming := FComboExportNaming.ItemIndex = 1;

  MarkerCount := 0;
  for i := 0 to High(FFrames) do
    if IsExportMarker(i) then Inc(MarkerCount);

  VolumeNo := 0;
  VolumeStart := 0;
  for i := 0 to FrameIdx do
    if IsExportMarker(i) then
    begin
      Inc(VolumeNo);
      VolumeStart := i;
    end;
  if VolumeNo = 0 then
    VolumeNo := 1;

  VolumeEnd := High(FFrames);
  for i := FrameIdx + 1 to High(FFrames) do
    if IsExportMarker(i) then
    begin
      VolumeEnd := i - 1;
      Break;
    end;
  FileNo := Max(1, FrameIdx - VolumeStart + 1);

  if UseArchiveNaming then
  begin
    ListCount := 0;
    LineText := '';
    if Assigned(FMemoArchiveList) then
      for i := 0 to FMemoArchiveList.Lines.Count - 1 do
      begin
        CleanLine := Trim(FMemoArchiveList.Lines[i]);
        if CleanLine = '' then Continue;
        Inc(ListCount);
        if ListCount = VolumeNo then
          LineText := CleanLine;
      end;

    if LineText = '' then
    begin
      Result := Format('Volume %d: missing archive list row | markers %d, rows %d',
        [VolumeNo, MarkerCount, ListCount]);
      Exit;
    end;

    Parts := TStringList.Create;
    try
      CleanLine := LineText;
      while CleanLine <> '' do
      begin
        if CleanLine[1] <> ';' then Break;
        Delete(CleanLine, 1, 1);
      end;
      Parts.StrictDelimiter := True;
      Parts.Delimiter := ';';
      Parts.DelimitedText := CleanLine;

      FolderPath := OutputRoot;
      Prefix := '';
      for i := 0 to Parts.Count - 1 do
      begin
        if Trim(Parts[i]) = '' then Continue;
        FolderPath := IncludeTrailingPathDelimiter(FolderPath) + Trim(Parts[i]);
        if Prefix <> '' then Prefix := Prefix + '_';
        Prefix := Prefix + Trim(Parts[i]);
      end;
      if Prefix = '' then
        Prefix := 'archive';
      FileName := Prefix + '_' + ZeroPadInt(FileNo, FSpinFileDigits.Value) + '.jpg';
      Result := Format('Vol %d/%d row %d/%d | %s | %s',
        [VolumeNo, Max(1, MarkerCount), VolumeNo, ListCount, FolderPath, FileName]);
    finally
      Parts.Free;
    end;
  end
  else
  begin
    FolderName := ZeroPadInt(VolumeNo, FSpinFileDigits.Value);
    FileName := FEdtPrefix.Text + ZeroPadInt(FileNo, FSpinFileDigits.Value) + '.jpg';
    if IncludeOutputRoot then
      FolderPath := IncludeTrailingPathDelimiter(OutputRoot) + FolderName
    else
      FolderPath := FolderName;
    Result := Format('Vol %d/%d | %s | %s',
      [VolumeNo, Max(1, MarkerCount), FolderPath, FileName]);
  end;
end;

procedure TMainForm.StoreAdjustmentControlsToRoll;
begin
  if Assigned(FChkPerFrame) then
    if FChkPerFrame.Checked then Exit;
  if Assigned(FComboAdjustMethod) then
    FRollData.StriplightAdjustMethod := FComboAdjustMethod.ItemIndex;
  FRollData.StriplightAdjustFlags := CurrentAdjustmentFlags;
  if Assigned(FTrackContrast) then
    FRollData.StriplightAdjustContrast := FTrackContrast.Position;
  if Assigned(FTrackBrightness) then
    FRollData.StriplightAdjustBrightness := FTrackBrightness.Position;
  if Assigned(FTrackGamma) then
    FRollData.StriplightAdjustGamma := FTrackGamma.Position;
  if Assigned(FTrackSharpness) then
    FRollData.StriplightSharpness := FTrackSharpness.Position;
  if Assigned(FComboSharpnessMode) then
    FRollData.StriplightSharpnessMode := FComboSharpnessMode.ItemIndex;
  if Assigned(FComboAdjustMethod) and (FComboAdjustMethod.ItemIndex in [0, 1, 4]) then
  begin
    FRollData.SoftwareContrast := FRollData.StriplightAdjustContrast;
    FRollData.SoftwareBrightness := FRollData.StriplightAdjustBrightness;
    FRollData.SoftwareGamma := FRollData.StriplightAdjustGamma;
  end;
end;

procedure TMainForm.StoreExportNamingControlsToRoll;
begin
  if Assigned(FComboExportNaming) then
    FRollData.StriplightExportNamingMode := FComboExportNaming.ItemIndex;
  if Assigned(FMemoArchiveList) then
    FRollData.StriplightArchiveList := FMemoArchiveList.Lines.Text;
  if Assigned(FSpinQuality) then
    FRollData.JpgQuality := FSpinQuality.Value;
  if Assigned(FChkExportGrayscale) then
    FRollData.StriplightExportGrayscale := FChkExportGrayscale.Checked;
  if Assigned(FChkExportProgressive) then
    FRollData.StriplightExportProgressive := FChkExportProgressive.Checked;
  if Assigned(FComboExportEncoder) then
    FRollData.StriplightExportEncoder := FComboExportEncoder.ItemIndex;
end;

procedure TMainForm.LoadExportNamingControlsFromRoll;
begin
  FUpdatingExportNaming := True;
  try
    { Populate the memo before controls whose OnChange handlers store all export
      settings. The guard also prevents a load from writing partial UI state back
      over the freshly parsed SLF values. }
    if Assigned(FMemoArchiveList) then
      FMemoArchiveList.Lines.Text := FRollData.StriplightArchiveList;
    if Assigned(FComboExportNaming) then
      FComboExportNaming.ItemIndex := Max(0, Min(FComboExportNaming.Items.Count - 1,
        FRollData.StriplightExportNamingMode));
    if Assigned(FChkExportGrayscale) then
      FChkExportGrayscale.Checked := FRollData.StriplightExportGrayscale;
    if Assigned(FChkExportProgressive) then
      FChkExportProgressive.Checked := FRollData.StriplightExportProgressive;
    if Assigned(FComboExportEncoder) then
      FComboExportEncoder.ItemIndex := Max(0, Min(FComboExportEncoder.Items.Count - 1,
        FRollData.StriplightExportEncoder));
  finally
    FUpdatingExportNaming := False;
  end;
  UpdateStatus;
end;

procedure TMainForm.LoadAdjustmentControlsFromRoll;
var
  MethodIdx, Flags: Integer;
begin
  if not Assigned(FComboAdjustMethod) then Exit;
  MethodIdx := Max(0, Min(FComboAdjustMethod.Items.Count - 1,
                          FRollData.StriplightAdjustMethod));
  FComboAdjustMethod.ItemIndex := MethodIdx;
  OnAdjustmentMethodChanged(Self);

  Flags := FRollData.StriplightAdjustFlags;
  FUpdatingAdjustments := True;
  try
    if Assigned(FChkShadowLift) then
      FChkShadowLift.Checked := (Flags and ADJ_FLAG_SHADOW_LIFT) <> 0;
    if Assigned(FChkHighlightRecovery) then
      FChkHighlightRecovery.Checked := (Flags and ADJ_FLAG_HIGHLIGHT_RECOVERY) <> 0;
    if Assigned(FChkSCurveContrast) then
      FChkSCurveContrast.Checked := (Flags and ADJ_FLAG_S_CURVE) <> 0;
    if Assigned(FChkDocumentRescue) then
      FChkDocumentRescue.Checked := (Flags and ADJ_FLAG_DOCUMENT_RESCUE) <> 0;
    if Assigned(FChkSoftContrast) then
      FChkSoftContrast.Checked := (Flags and ADJ_FLAG_SOFT_CONTRAST) <> 0;

    FTrackContrast.Position := Max(FTrackContrast.Min,
      Min(FTrackContrast.Max, FRollData.StriplightAdjustContrast));
    FTrackBrightness.Position := Max(FTrackBrightness.Min,
      Min(FTrackBrightness.Max, FRollData.StriplightAdjustBrightness));
    FTrackGamma.Position := Max(FTrackGamma.Min,
      Min(FTrackGamma.Max, FRollData.StriplightAdjustGamma));
    FSpinContrast.Value := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value := FTrackGamma.Position;
    if Assigned(FTrackSharpness) then
      FTrackSharpness.Position := Max(FTrackSharpness.Min,
        Min(FTrackSharpness.Max, FRollData.StriplightSharpness));
    if Assigned(FSpinSharpness) then
      FSpinSharpness.Value := FTrackSharpness.Position;
    if Assigned(FComboSharpnessMode) then
      FComboSharpnessMode.ItemIndex := Max(0, Min(FComboSharpnessMode.Items.Count - 1,
        FRollData.StriplightSharpnessMode));
  finally
    FUpdatingAdjustments := False;
  end;
end;

procedure TMainForm.ApplyAdjustmentControlsToSelectedFrames;
var
  i: Integer;
  UseQuantumPerFrame: Boolean;
  AnySelectedChanged: Boolean;
begin
  if not Assigned(FChkPerFrame) then Exit;
  if not FChkPerFrame.Checked then Exit;
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  UseQuantumPerFrame := Assigned(FComboAdjustMethod) and
    (FComboAdjustMethod.ItemIndex in [1, 4]);
  AnySelectedChanged := False;

  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
    begin
      if UseQuantumPerFrame then
      begin
        FFrames[i].PerFrameContrast := FTrackContrast.Position;
        FFrames[i].PerFrameBrightness := FTrackBrightness.Position;
        FFrames[i].PerFrameGamma := FTrackGamma.Position;
      end;
      FFrames[i].CustomContrast := FTrackContrast.Position;
      FFrames[i].CustomBrightness := FTrackBrightness.Position;
      FFrames[i].CustomGamma := FTrackGamma.Position;
      FFrames[i].HasOverride := True;
      AnySelectedChanged := True;
    end;

  if not AnySelectedChanged then Exit;
  FStripView.UpdateFrames(FFrames);
  RefreshFrameColors;
  MarkDirty;
  UpdateStatus;
  UpdateSelectedAdjustmentStatus;
end;

procedure TMainForm.UpdateSelectedAdjustmentStatus;
var
  i, SelCount, OverrideCount: Integer;
  C, B, G, R: Integer;
  FH, FV, Neg: Boolean;
  TC, TB, TG, TR: Integer;
  TFH, TFV, TNeg: Boolean;
  Mixed: Boolean;

  function FrameHasAnyOverride(const F: TFrameRecord): Boolean;
  begin
    Result := (F.PerFrameContrast <> -1) or
              (F.PerFrameBrightness <> -1) or
              (F.PerFrameGamma <> -1) or
              (F.CustomContrast <> -1) or
              (F.CustomBrightness <> -1) or
              (F.CustomGamma <> -1) or
              (F.Rotation <> 0) or F.FlipH or F.FlipV or F.Negative or
              F.HasOverride;
  end;

  procedure FrameOverrideValues(const F: TFrameRecord; out AC, AB, AG, AR: Integer;
    out AFH, AFV, ANeg: Boolean);
  begin
    AC := FTrackContrast.Position;
    AB := FTrackBrightness.Position;
    AG := FTrackGamma.Position;
    AR := F.Rotation;
    AFH := F.FlipH;
    AFV := F.FlipV;
    ANeg := F.Negative;
    if F.PerFrameContrast <> -1 then
      AC := F.PerFrameContrast
    else if F.CustomContrast <> -1 then
      AC := F.CustomContrast;
    if F.PerFrameBrightness <> -1 then
      AB := F.PerFrameBrightness
    else if F.CustomBrightness <> -1 then
      AB := F.CustomBrightness;
    if F.PerFrameGamma <> -1 then
      AG := F.PerFrameGamma
    else if F.CustomGamma <> -1 then
      AG := F.CustomGamma;
  end;

  function FlipText(AFH, AFV: Boolean): String;
  begin
    Result := '';
    if AFH then Result := Result + 'H';
    if AFV then Result := Result + 'V';
    if Result = '' then Result := '-';
  end;

  procedure LoadSameValuesToControls;
  begin
    if not Assigned(FChkPerFrame) then Exit;
    if not FChkPerFrame.Checked then Exit;
    FUpdatingAdjustments := True;
    try
      FTrackContrast.Position := Max(FTrackContrast.Min, Min(FTrackContrast.Max, C));
      FTrackBrightness.Position := Max(FTrackBrightness.Min, Min(FTrackBrightness.Max, B));
      FTrackGamma.Position := Max(FTrackGamma.Min, Min(FTrackGamma.Max, G));
      FSpinContrast.Value := FTrackContrast.Position;
      FSpinBrightness.Value := FTrackBrightness.Position;
      FSpinGamma.Value := FTrackGamma.Position;
      FRbRotM90.Checked := R = 270;
      FRbRot0.Checked := R = 0;
      FRbRot90.Checked := R = 90;
      FRbRot180.Checked := R = 180;
      FChkMirror.Checked := FH;
      FChkNegative.Checked := Neg;
    finally
      FUpdatingAdjustments := False;
    end;
  end;

begin
  if not Assigned(FLblSelectedAdjustment) then Exit;
  if not FRollData.Loaded then
  begin
    FLblSelectedAdjustment.Caption := 'Selected override: none';
    Exit;
  end;

  SelCount := 0;
  OverrideCount := 0;
  C := 0;
  B := 0;
  G := 100;
  R := 0;
  FH := False;
  FV := False;
  Neg := False;
  Mixed := False;

  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
    begin
      Inc(SelCount);
      if FrameHasAnyOverride(FFrames[i]) then
      begin
        FrameOverrideValues(FFrames[i], TC, TB, TG, TR, TFH, TFV, TNeg);
        if OverrideCount = 0 then
        begin
          C := TC;
          B := TB;
          G := TG;
          R := TR;
          FH := TFH;
          FV := TFV;
          Neg := TNeg;
        end
        else if (TC <> C) or (TB <> B) or (TG <> G) or
                (TR <> R) or (TFH <> FH) or (TFV <> FV) or (TNeg <> Neg) then
          Mixed := True;
        Inc(OverrideCount);
      end
      else if OverrideCount > 0 then
        Mixed := True;
    end;

  if SelCount = 0 then
    FLblSelectedAdjustment.Caption := 'Selected override: none'
  else if OverrideCount = 0 then
    FLblSelectedAdjustment.Caption := Format('Selected: %d frame(s), using global settings', [SelCount])
  else if Mixed or (OverrideCount <> SelCount) then
    FLblSelectedAdjustment.Caption := Format('Selected override: mixed (%d/%d changed)', [OverrideCount, SelCount])
  else
  begin
    FLblSelectedAdjustment.Caption := Format('Override: C%d B%d G%d R%d F%s',
      [C, B, G, R, FlipText(FH, FV)]);
    LoadSameValuesToControls;
  end;
end;

procedure TMainForm.SetProcessRotation(Rot: Integer);
begin
  Rot := ((Rot mod 360) + 360) mod 360;
  FUpdatingAdjustments := True;
  try
    FRbRotM90.Checked := Rot = 270;
    FRbRot0.Checked := Rot = 0;
    FRbRot90.Checked := Rot = 90;
    FRbRot180.Checked := Rot = 180;
  finally
    FUpdatingAdjustments := False;
  end;
end;

procedure TMainForm.ShowFramePreview(FrameIdx: Integer);
var
  Panel: TPanel;
  Btn: TBitBtn;

  function AddButton(const Caption: String; TagValue, X, W: Integer;
    Handler: TNotifyEvent): TBitBtn;
  begin
    Result := TBitBtn.Create(FPreviewForm);
    Result.Parent := Panel;
    Result.Caption := ButtonCaptionWithIcon(Caption);
    ApplyButtonStyle(Result);
    ApplyButtonGlyph(Result, Caption);
    Result.Left := X;
    Result.Top := 4;
    Result.Width := W;
    Result.Height := 25;
    Result.Tag := TagValue;
    Result.OnClick := Handler;
  end;

begin
  if not FRollData.Loaded then Exit;
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  if Assigned(FPreviewForm) then
  begin
    PreviewSelectFrame(FrameIdx);
    FPreviewForm.Show;
    FPreviewForm.BringToFront;
    Exit;
  end;

  FPreviewFrameIdx := FrameIdx;
  if FPreviewKeepOneToOne then
    FPreviewZoomPct := 100
  else
    FPreviewZoomPct := 0;
  FPreviewPanning := False;
  FPreviewForm := TForm.Create(Self);
  FPreviewForm.Caption := 'Frame Preview';
  FPreviewForm.Position := poMainFormCenter;
  FPreviewForm.Width := 900;
  FPreviewForm.Height := 700;
  FPreviewForm.KeyPreview := True;
  FPreviewForm.OnKeyDown := @OnPreviewWindowKeyDown;
  FPreviewForm.OnClose := @OnPreviewFormClose;

  FPreviewStatus := TLabel.Create(FPreviewForm);
  FPreviewStatus.Parent := FPreviewForm;
  FPreviewStatus.Align := alTop;
  FPreviewStatus.Height := 24;
  FPreviewStatus.BorderSpacing.Left := 8;
  FPreviewStatus.BorderSpacing.Top := 4;

  Panel := TPanel.Create(FPreviewForm);
  Panel.Parent := FPreviewForm;
  Panel.Align := alTop;
  Panel.Height := 64;
  Panel.BevelOuter := bvNone;

  AddButton('X Prev Frame', 1, 8, 96, @OnPreviewNavButton);
  AddButton('C Next Frame', 2, 110, 96, @OnPreviewNavButton);
  AddButton('G Prev Marker', 3, 214, 104, @OnPreviewNavButton);
  AddButton('F Next Marker', 4, 324, 104, @OnPreviewNavButton);

  MakeLabel(Panel, 'Frame step:', 442, 8);
  FPreviewFrameStep := TSpinEdit.Create(FPreviewForm);
  FPreviewFrameStep.Parent := Panel;
  FPreviewFrameStep.Left := 510;
  FPreviewFrameStep.Top := 4;
  FPreviewFrameStep.Width := 64;
  FPreviewFrameStep.MinValue := 1;
  FPreviewFrameStep.MaxValue := Max(1, Length(FFrames));
  FPreviewFrameStep.Value := 1;
  FPreviewFrameStep.Hint := 'Number of frames moved by Previous Frame and Next Frame';
  FPreviewFrameStep.ShowHint := True;

  Btn := AddButton('Rot -90', -90, 8, 78, @OnPreviewProcessButton);
  Btn.Top := 34;
  Btn := AddButton('Rot +90', 90, 92, 78, @OnPreviewProcessButton);
  Btn.Top := 34;
  Btn := AddButton('Mirror (M)', 1, 176, 98, @OnPreviewProcessButton);
  Btn.Top := 34;
  Btn := AddButton('Negative (N)', 2, 280, 104, @OnPreviewProcessButton);
  Btn.Top := 34;

  FPreviewFullRes := TCheckBox.Create(FPreviewForm);
  FPreviewFullRes.Parent := Panel;
  FPreviewFullRes.Caption := 'Full quality';
  FPreviewFullRes.Left := 400;
  FPreviewFullRes.Top := 38;
  FPreviewFullRes.Width := 120;
  FPreviewFullRes.Checked := FPreviewKeepFullRes;
  FPreviewFullRes.OnChange := @OnPreviewQualityToggle;

  FPreviewOneToOne := TCheckBox.Create(FPreviewForm);
  FPreviewOneToOne.Parent := Panel;
  FPreviewOneToOne.Caption := '1:1 pixels';
  FPreviewOneToOne.Left := 520;
  FPreviewOneToOne.Top := 38;
  FPreviewOneToOne.Width := 100;
  FPreviewOneToOne.Checked := FPreviewKeepOneToOne;
  FPreviewOneToOne.OnChange := @OnPreviewQualityToggle;

  FPreviewTopMost := TCheckBox.Create(FPreviewForm);
  FPreviewTopMost.Parent := Panel;
  FPreviewTopMost.Caption := 'Always on top';
  FPreviewTopMost.Left := 630;
  FPreviewTopMost.Top := 38;
  FPreviewTopMost.Width := 130;
  FPreviewTopMost.Checked := FPreviewKeepTopMost;
  FPreviewTopMost.OnChange := @OnPreviewTopMostToggle;
  OnPreviewTopMostToggle(FPreviewTopMost);

  FPreviewScroll := TScrollBox.Create(FPreviewForm);
  FPreviewScroll.Parent := FPreviewForm;
  FPreviewScroll.Align := alClient;
  FPreviewScroll.AutoScroll := True;
  FPreviewScroll.OnMouseWheel := @OnPreviewMouseWheel;
  FPreviewScroll.OnMouseDown := @OnPreviewMouseDown;
  FPreviewScroll.OnMouseMove := @OnPreviewMouseMove;
  FPreviewScroll.OnMouseUp := @OnPreviewMouseUp;
  FPreviewScroll.OnResize := @OnPreviewScrollResize;

  FPreviewImage := TImage.Create(FPreviewScroll);
  FPreviewImage.Parent := FPreviewScroll;
  FPreviewImage.Left := 0;
  FPreviewImage.Top := 0;
  FPreviewImage.Stretch := True;
  FPreviewImage.Proportional := True;
  FPreviewImage.Center := True;
  FPreviewImage.AutoSize := False;
  FPreviewImage.OnMouseWheel := @OnPreviewMouseWheel;
  FPreviewImage.OnMouseDown := @OnPreviewMouseDown;
  FPreviewImage.OnMouseMove := @OnPreviewMouseMove;
  FPreviewImage.OnMouseUp := @OnPreviewMouseUp;

  PreviewSelectFrame(FrameIdx);
  FPreviewForm.Show;
end;

procedure TMainForm.OnPreviewFormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if Assigned(FPreviewFullRes) then
    FPreviewKeepFullRes := FPreviewFullRes.Checked;
  if Assigned(FPreviewOneToOne) then
    FPreviewKeepOneToOne := FPreviewOneToOne.Checked;
  if Assigned(FPreviewTopMost) then
    FPreviewKeepTopMost := FPreviewTopMost.Checked;
  FPreviewPanning := False;
  FPreviewImage := nil;
  FPreviewScroll := nil;
  FPreviewStatus := nil;
  FPreviewFrameStep := nil;
  FPreviewFullRes := nil;
  FPreviewOneToOne := nil;
  FPreviewTopMost := nil;
  FPreviewForm := nil;
  CloseAction := caFree;
end;

procedure TMainForm.ApplyPreviewZoom;
var
  Bmp: TBitmap;
  NewW, NewH, ZoomPct: Integer;
  ScaleX, ScaleY, Scale: Double;
  FitW, FitH, NewLeft, NewTop: Integer;
begin
  if (not Assigned(FPreviewImage)) or (not Assigned(FPreviewScroll)) then Exit;
  if FApplyingPreviewZoom then Exit;
  Bmp := FPreviewImage.Picture.Bitmap;
  if (Bmp = nil) or (Bmp.Width <= 0) or (Bmp.Height <= 0) then Exit;

  FApplyingPreviewZoom := True;
  try
  if FPreviewZoomPct <= 0 then
  begin
    FitW := Max(1, FPreviewScroll.ClientWidth - 8);
    FitH := Max(1, FPreviewScroll.ClientHeight - 8);
    ScaleX := FitW / Bmp.Width;
    ScaleY := FitH / Bmp.Height;
    Scale := Min(ScaleX, ScaleY);
    if Scale <= 0 then Scale := 1.0;
    ZoomPct := Max(5, Min(1600, Round(Scale * 100.0)));
  end
  else
    ZoomPct := FPreviewZoomPct;

  NewW := Max(1, Round(Bmp.Width * ZoomPct / 100.0));
  NewH := Max(1, Round(Bmp.Height * ZoomPct / 100.0));
  NewLeft := Max(0, (FPreviewScroll.ClientWidth - NewW) div 2);
  NewTop := Max(0, (FPreviewScroll.ClientHeight - NewH) div 2);
  if (FPreviewImage.Left <> NewLeft) or (FPreviewImage.Top <> NewTop) or
     (FPreviewImage.Width <> NewW) or (FPreviewImage.Height <> NewH) then
    FPreviewImage.SetBounds(NewLeft, NewTop, NewW, NewH);
  finally
    FApplyingPreviewZoom := False;
  end;
end;

procedure TMainForm.FitPreviewZoom;
begin
  if (not Assigned(FPreviewImage)) or (not Assigned(FPreviewScroll)) then Exit;
  FPreviewZoomPct := 0;
  ApplyPreviewZoom;
end;

procedure TMainForm.RenderFramePreview;
var
  FrameIdx, FirstStrip, LastStrip, StripIdx, DS: Integer;
  F: TFrameRecord;
  DisplayBmp: TBitmap;
  Source, OrientedBmp, CropBmp, ScaledBmp, SegmentBmp, ComposedBmp, ProcessedBmp, TempBmp: TBGRABitmap;
  SourcePath, QualityLabel, LoadErr: String;
  LocalLead, LocalTrail: Int64;
  SrcLeft, SrcRight, SrcTop, SrcBottom: Integer;
  SegW, SegH, SourceW, SourceH, TotalW, MaxH, OffsetX: Integer;
  Rot: Integer;
  SourceScale: Integer;
  FullFrameW, FullFrameH: Int64;
  DoMirror, DoFlipV, DoNegative: Boolean;
  UseFullSource, FullRequested, FullOneToOne, FullAvailable: Boolean;
  AdjustMethod, AdjustFlags, AdjustContrast, AdjustBrightness, AdjustGamma: Integer;
  SegmentRects: array of TRect;
  Missing: TStringList;
  HadView: Boolean;
  OldLeft, OldTop, OldW, OldH, OldCenterX, OldCenterY: Integer;
  RelX, RelY: Double;

  function ClampInt(Value, Lo, Hi: Integer): Integer;
  begin
    Result := Max(Lo, Min(Hi, Value));
  end;

  procedure ApplyNegative(ABitmap: TBGRABitmap);
  var
    NX, NY: Integer;
    P: PBGRAPixel;
  begin
    if ABitmap = nil then Exit;
    for NY := 0 to ABitmap.Height - 1 do
    begin
      P := ABitmap.ScanLine[NY];
      for NX := 0 to ABitmap.Width - 1 do
      begin
        P^.red := 255 - P^.red;
        P^.green := 255 - P^.green;
        P^.blue := 255 - P^.blue;
        Inc(P);
      end;
    end;
  end;

  procedure ApplyGrayAdjustment(ABitmap: TBGRABitmap);
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
    NX, NY: Integer;
    LUT: array[0..255] of Byte;
    P: PBGRAPixel;

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
      if AdjustMethod in [2, 3, 4] then
      begin
        In12 := Round(V * 4095.0);
        if AdjustMethod = 3 then
          Out12 := CURVE_GAMMA12_OUT[CURVE_POINT_COUNT - 1]
        else
          Out12 := CURVE_OUT[CURVE_POINT_COUNT - 1];
        for I := 0 to CURVE_POINT_COUNT - 2 do
          if In12 <= CURVE_IN[I + 1] then
          begin
            if CURVE_IN[I + 1] = CURVE_IN[I] then
            begin
              if AdjustMethod = 3 then
                Out12 := CURVE_GAMMA12_OUT[I]
              else
                Out12 := CURVE_OUT[I];
            end
            else
            begin
              if AdjustMethod = 3 then
                Out12 := CURVE_GAMMA12_OUT[I] +
                  Round((Int64(In12 - CURVE_IN[I]) *
                        (CURVE_GAMMA12_OUT[I + 1] - CURVE_GAMMA12_OUT[I])) /
                        (CURVE_IN[I + 1] - CURVE_IN[I]))
              else
                Out12 := CURVE_OUT[I] +
                  Round((Int64(In12 - CURVE_IN[I]) *
                        (CURVE_OUT[I + 1] - CURVE_OUT[I])) /
                        (CURVE_IN[I + 1] - CURVE_IN[I]));
            end;
            Break;
        end;
        V := Out12 / 4095.0;

        if AdjustMethod = 4 then
        begin
          G := Power(2.0, -AdjustGamma / 255.0);
          if G <= 0.01 then G := 1.0;
          V := Power(V, 1.0 / G);

          C := Power(2.0, (AdjustContrast - 64) / 128.0);
          V := ((V - 0.5) * C) + 0.5;
          V := V - (AdjustBrightness / 510.0);
        end
        else
        begin
          G := AdjustGamma / 100.0;
          if G <= 0.01 then G := 1.0;
          V := Power(V, 1.0 / G);

          C := (100.0 + AdjustContrast) / 100.0;
          V := ((V - 0.5) * C) + 0.5;
          V := V + (AdjustBrightness / 100.0);
        end;
      end
      else if AdjustMethod = 1 then
      begin
        G := Power(2.0, -AdjustGamma / 255.0);
        if G <= 0.01 then G := 1.0;
        V := Power(V, 1.0 / G);

        C := Power(2.0, (AdjustContrast - 64) / 128.0);
        V := ((V - 0.5) * C) + 0.5;
        V := V - (AdjustBrightness / 510.0);
      end
      else
      begin
        G := AdjustGamma / 100.0;
        if G <= 0.01 then G := 1.0;
        V := Power(V, 1.0 / G);

        C := (100.0 + AdjustContrast) / 100.0;
        V := ((V - 0.5) * C) + 0.5;
        V := V + (AdjustBrightness / 100.0);
      end;

      if (AdjustFlags and ADJ_FLAG_SHADOW_LIFT) <> 0 then
        V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.45);
      if (AdjustFlags and ADJ_FLAG_HIGHLIGHT_RECOVERY) <> 0 then
        V := V / (V + (1.0 - V) * 1.20);
      if (AdjustFlags and ADJ_FLAG_S_CURVE) <> 0 then
        V := V * V * (3.0 - 2.0 * V);
      if (AdjustFlags and ADJ_FLAG_DOCUMENT_RESCUE) <> 0 then
      begin
        V := Power(Max(0.0, Min(1.0, V)), 1.0 / 1.35);
        if V > 0.70 then
          V := 0.70 + (V - 0.70) * 0.72;
      end;
      if (AdjustFlags and ADJ_FLAG_SOFT_CONTRAST) <> 0 then
      begin
        V := ((V - 0.5) * 0.82) + 0.5;
        if V < 0 then V := 0
        else if V > 1 then V := 1;
        V := Power(V, 1.0 / 1.08);
      end;
      Result := ClampByte(Round(V * 255.0));
    end;

  begin
    if (ABitmap = nil) or (not Assigned(FChkAdjustPreview)) or
       (not FChkAdjustPreview.Checked) then Exit;
    if AdjustMethod = 1 then
    begin
      if (AdjustBrightness = 0) and
         (AdjustContrast = 64) and
         (AdjustGamma = 0) then Exit;
    end
    else if (AdjustMethod in [2, 3, 4]) or
            (AdjustFlags <> 0) then
    begin
      { The curve itself is an adjustment, even when the fine-tune sliders are neutral. }
    end
    else if (AdjustBrightness = 0) and
            (AdjustContrast = 0) and
            (AdjustGamma = 100) then Exit;

    for NX := 0 to 255 do
      LUT[NX] := AdjustChannel(NX);

    for NY := 0 to ABitmap.Height - 1 do
    begin
      P := ABitmap.ScanLine[NY];
      for NX := 0 to ABitmap.Width - 1 do
      begin
        P^.red := LUT[P^.red];
        P^.green := LUT[P^.green];
        P^.blue := LUT[P^.blue];
        Inc(P);
      end;
    end;
  end;

  function StripHasVisibleFramePart(AStripIdx: Integer): Boolean;
  var
    LLead, LTrail: Int64;
  begin
    LLead := F.LeadEdge - Int64(AStripIdx) * FRollData.LengthLines;
    LTrail := F.TrailEdge - Int64(AStripIdx) * FRollData.LengthLines;
    if LLead < 0 then LLead := 0;
    if LTrail > FRollData.LengthLines then LTrail := FRollData.LengthLines;
    Result := LTrail > LLead;
  end;

  function FrameFullStripFilesAvailable: Boolean;
  var
    S: Integer;
  begin
    Result := True;
    for S := FirstStrip to LastStrip do
      if StripHasVisibleFramePart(S) and (not FileExists(StripFilePath(FRollData, S))) then
        Exit(False);
  end;

  function CurrentSourcePath(AStripIdx: Integer): String;
  begin
    if UseFullSource then
      Result := StripFilePath(FRollData, AStripIdx)
    else
      Result := PreviewFilePath(FRollData, AStripIdx);
  end;

  function LoadPreviewSource(const Path: String): TBGRABitmap;
  var
    Ext: String;
  begin
    Result := nil;
    LoadErr := '';
    Ext := LowerCase(ExtractFileExt(Path));
    if ((Ext = '.jpg') or (Ext = '.jpeg')) and TurboJPEGAvailable then
      if LoadTurboJPEG(Path, Result, LoadErr) then
        Exit;
    Result := TBGRABitmap.Create(Path);
  end;

  function CeilDiv64(Value, Divisor: Int64): Integer;
  begin
    if Divisor <= 0 then Exit(1);
    if Value <= 0 then Exit(1);
    Result := Integer((Value + Divisor - 1) div Divisor);
    if Result < 1 then Result := 1;
  end;

  function ScaledSize(Value: Integer): Integer;
  begin
    if UseFullSource then
      Result := CeilDiv64(Value, SourceScale)
    else
      Result := Value;
    if Result < 1 then Result := 1;
  end;

begin
  if not FRollData.Loaded then Exit;
  if not Assigned(FPreviewImage) then Exit;
  HadView := Assigned(FPreviewScroll) and (FPreviewImage.Width > 0) and
    (FPreviewImage.Height > 0);
  if HadView then
  begin
    OldLeft := FPreviewImage.Left;
    OldTop := FPreviewImage.Top;
    OldW := FPreviewImage.Width;
    OldH := FPreviewImage.Height;
    OldCenterX := FPreviewScroll.HorzScrollBar.Position +
      FPreviewScroll.ClientWidth div 2 - OldLeft;
    OldCenterY := FPreviewScroll.VertScrollBar.Position +
      FPreviewScroll.ClientHeight div 2 - OldTop;
    RelX := OldCenterX / Max(1, OldW);
    RelY := OldCenterY / Max(1, OldH);
    if RelX < 0 then RelX := 0 else if RelX > 1 then RelX := 1;
    if RelY < 0 then RelY := 0 else if RelY > 1 then RelY := 1;
  end
  else
  begin
    RelX := 0.5;
    RelY := 0.5;
  end;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  FrameIdx := FPreviewFrameIdx;
  if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  F := FFrames[FrameIdx];
  AdjustMethod := 0;
  if Assigned(FComboAdjustMethod) then
    AdjustMethod := FComboAdjustMethod.ItemIndex;
  AdjustFlags := CurrentAdjustmentFlags;
  AdjustContrast := FTrackContrast.Position;
  AdjustBrightness := FTrackBrightness.Position;
  AdjustGamma := FTrackGamma.Position;
  if (F.PerFrameContrast <> -1) or (F.PerFrameBrightness <> -1) or
     (F.PerFrameGamma <> -1) then
  begin
    AdjustMethod := 1;
    AdjustFlags := 0;
    AdjustContrast := 64;
    AdjustBrightness := 0;
    AdjustGamma := 0;
    if F.PerFrameContrast <> -1 then
      AdjustContrast := F.PerFrameContrast;
    if F.PerFrameBrightness <> -1 then
      AdjustBrightness := F.PerFrameBrightness;
    if F.PerFrameGamma <> -1 then
      AdjustGamma := F.PerFrameGamma;
  end
  else if (F.CustomContrast <> -1) or (F.CustomBrightness <> -1) or
          (F.CustomGamma <> -1) then
  begin
    if F.CustomContrast <> -1 then
      AdjustContrast := F.CustomContrast;
    if F.CustomBrightness <> -1 then
      AdjustBrightness := F.CustomBrightness;
    if F.CustomGamma <> -1 then
      AdjustGamma := F.CustomGamma;
  end;
  DS := Max(1, FRollData.PreviewDownScale);
  FirstStrip := FrameLeadStrip(F, FRollData.LengthLines);
  LastStrip  := FrameTrailStrip(F, FRollData.LengthLines);
  if FirstStrip < 0 then FirstStrip := 0;
  if LastStrip >= FRollData.StripCount then LastStrip := FRollData.StripCount - 1;
  if LastStrip < FirstStrip then LastStrip := FirstStrip;

  FullOneToOne := Assigned(FPreviewOneToOne) and FPreviewOneToOne.Checked;
  FullRequested := FullOneToOne or (Assigned(FPreviewFullRes) and FPreviewFullRes.Checked);
  FullAvailable := (not FullRequested) or FrameFullStripFilesAvailable;
  UseFullSource := FullRequested and FullAvailable;
  if UseFullSource then
  begin
    FullFrameW := Max(Int64(1), F.TrailEdge - F.LeadEdge);
    FullFrameH := Max(Int64(1), Int64(F.RightEdge - F.LeftEdge));
    if FullOneToOne then
      SourceScale := 1
    else
      SourceScale := Max(CeilDiv64(FullFrameW, 2400), CeilDiv64(FullFrameH, 2400));
    if SourceScale <= 1 then
      QualityLabel := 'Full quality'
    else
      QualityLabel := Format('Full source preview 1:%d', [SourceScale]);
  end
  else
  begin
    SourceScale := DS;
    if FullRequested then
      QualityLabel := 'Preview quality fallback'
    else
      QualityLabel := 'Preview quality';
  end;

  SetLength(SegmentRects, LastStrip - FirstStrip + 1);
  Missing := TStringList.Create;
  TotalW := 0;
  MaxH := 0;
  try
    for StripIdx := FirstStrip to LastStrip do
    begin
      LocalLead := F.LeadEdge - Int64(StripIdx) * FRollData.LengthLines;
      LocalTrail := F.TrailEdge - Int64(StripIdx) * FRollData.LengthLines;
      if LocalLead < 0 then LocalLead := 0;
      if LocalTrail > FRollData.LengthLines then LocalTrail := FRollData.LengthLines;
      if LocalTrail <= LocalLead then Continue;

      SourcePath := CurrentSourcePath(StripIdx);
      if not FileExists(SourcePath) then
      begin
        Missing.Add(ExtractFileName(SourcePath));
        Continue;
      end;

      if UseFullSource then
      begin
        SourceW := Max(1, FRollData.WidthPixels);
        SourceH := Max(1, FRollData.LengthLines);
        SrcLeft := ClampInt(LocalLead, 0, SourceH - 1);
        SrcRight := ClampInt(LocalTrail, SrcLeft + 1, SourceH);
        SrcTop := ClampInt(F.LeftEdge, 0, SourceW - 1);
        SrcBottom := ClampInt(F.RightEdge, SrcTop + 1, SourceW);
      end
      else
      begin
        SourceW := CeilDiv64(FRollData.WidthPixels, DS);
        SourceH := CeilDiv64(FRollData.LengthLines, DS);
        SrcLeft := ClampInt(LocalLead div DS, 0, SourceH - 1);
        SrcRight := ClampInt((LocalTrail + DS - 1) div DS, SrcLeft + 1, SourceH);
        SrcTop := ClampInt(F.LeftEdge div DS, 0, SourceW - 1);
        SrcBottom := ClampInt((F.RightEdge + DS - 1) div DS, SrcTop + 1, SourceW);
      end;

      SegW := ScaledSize(SrcRight - SrcLeft);
      SegH := ScaledSize(SrcBottom - SrcTop);
      SegmentRects[StripIdx - FirstStrip] := Rect(SrcLeft, SrcTop, SrcRight, SrcBottom);
      Inc(TotalW, SegW);
      if SegH > MaxH then MaxH := SegH;
    end;

    if (TotalW <= 0) or (MaxH <= 0) then
    begin
      if Missing.Count > 0 then
        ShowMessage('Could not load frame source image(s):'#13#10 + Missing.Text)
      else
        ShowMessage('This frame has no visible preview area.');
      Exit;
    end;

    ComposedBmp := TBGRABitmap.Create(TotalW, MaxH, BGRA(0, 0, 0));
    try
      OffsetX := 0;
      for StripIdx := FirstStrip to LastStrip do
      begin
        SrcLeft := SegmentRects[StripIdx - FirstStrip].Left;
        SrcTop := SegmentRects[StripIdx - FirstStrip].Top;
        SrcRight := SegmentRects[StripIdx - FirstStrip].Right;
        SrcBottom := SegmentRects[StripIdx - FirstStrip].Bottom;
        if (SrcRight <= SrcLeft) or (SrcBottom <= SrcTop) then Continue;

        SourcePath := CurrentSourcePath(StripIdx);
        if not FileExists(SourcePath) then Continue;

        Source := LoadPreviewSource(SourcePath);
        CropBmp := nil;
        ScaledBmp := nil;
        SegmentBmp := nil;
        try
          SrcTop := ClampInt(SrcTop, 0, Source.Width - 1);
          SrcBottom := ClampInt(SrcBottom, SrcTop + 1, Source.Width);
          SrcLeft := ClampInt(SrcLeft, 0, Source.Height - 1);
          SrcRight := ClampInt(SrcRight, SrcLeft + 1, Source.Height);
          CropBmp := Source.GetPart(Rect(SrcTop, SrcLeft, SrcBottom, SrcRight));
          if UseFullSource and (SourceScale > 1) then
          begin
            ScaledBmp := CropBmp.Resample(ScaledSize(CropBmp.Width), ScaledSize(CropBmp.Height), rmSimpleStretch);
            FreeAndNil(CropBmp);
          end
          else
          begin
            ScaledBmp := CropBmp;
            CropBmp := nil;
          end;

          if FStripView.RotateCW then
          begin
            SegmentBmp := ScaledBmp.RotateCW;
            SegmentBmp.HorizontalFlip;
          end
          else
            SegmentBmp := ScaledBmp.RotateCCW;
          ScaledBmp := nil;
          ComposedBmp.PutImage(OffsetX, 0, SegmentBmp, dmSet);
          Inc(OffsetX, SegmentBmp.Width);
        finally
          SegmentBmp.Free;
          ScaledBmp.Free;
          CropBmp.Free;
          Source.Free;
        end;
      end;

      if F.HasOverride then
      begin
        Rot := F.Rotation;
        DoMirror := F.FlipH;
        DoFlipV := F.FlipV;
        DoNegative := F.Negative;
      end
      else
      begin
        Rot := CurrentProcessRotation;
        DoMirror := FChkMirror.Checked;
        DoFlipV := False;
        DoNegative := FChkNegative.Checked;
      end;
      Rot := ((Rot mod 360) + 360) mod 360;
      if (Rot <> 0) and (Rot <> 90) and (Rot <> 180) and (Rot <> 270) then Rot := 0;

      ProcessedBmp := nil;
      TempBmp := nil;
      try
        case Rot of
          90:
            ProcessedBmp := ComposedBmp.RotateCW;
          180:
            begin
              TempBmp := ComposedBmp.RotateCW;
              ProcessedBmp := TempBmp.RotateCW;
            end;
          270:
            ProcessedBmp := ComposedBmp.RotateCCW;
        else
          ProcessedBmp := ComposedBmp.GetPart(Rect(0, 0, ComposedBmp.Width, ComposedBmp.Height));
        end;

        if DoMirror then
          ProcessedBmp.HorizontalFlip;
        if DoFlipV then
          ProcessedBmp.VerticalFlip;
        ApplyGrayAdjustment(ProcessedBmp);
        if DoNegative then
          ApplyNegative(ProcessedBmp);
        if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked and
           Assigned(FTrackSharpness) then
          ApplySharpnessFilter(ProcessedBmp,
            IfThen(Assigned(FComboSharpnessMode), FComboSharpnessMode.ItemIndex, 0),
            FTrackSharpness.Position);

        FPreviewForm.Caption := Format('Frame Preview - Frame %d', [FrameIdx + 1]);
        DisplayBmp := ProcessedBmp.MakeBitmapCopy(clBlack);
        try
          FPreviewImage.Picture.Bitmap.Assign(DisplayBmp);
          if FullOneToOne then
            FPreviewZoomPct := 100;
          ApplyPreviewZoom;
          if HadView and Assigned(FPreviewScroll) then
          begin
            FPreviewScroll.HorzScrollBar.Position := Max(0,
              FPreviewImage.Left + Round(RelX * FPreviewImage.Width) -
              FPreviewScroll.ClientWidth div 2);
            FPreviewScroll.VertScrollBar.Position := Max(0,
              FPreviewImage.Top + Round(RelY * FPreviewImage.Height) -
              FPreviewScroll.ClientHeight div 2);
          end;
        finally
          DisplayBmp.Free;
        end;
        if Assigned(FPreviewStatus) then
          FPreviewStatus.Caption := Format('%s   Frame %d / %d   %d x %d px   Rotation %d   FlipH %s   FlipV %s   Negative %s',
            [QualityLabel, FrameIdx + 1, Length(FFrames), ProcessedBmp.Width, ProcessedBmp.Height, Rot,
             BoolToStr(DoMirror, True), BoolToStr(DoFlipV, True), BoolToStr(DoNegative, True)]) +
             '   ' + ExportNamingPreviewForFrame(FrameIdx, False);
      finally
        TempBmp.Free;
        ProcessedBmp.Free;
      end;
    finally
      ComposedBmp.Free;
    end;
  finally
    Missing.Free;
  end;
end;

procedure TMainForm.PreviewSelectFrame(FrameIdx: Integer);
var
  StripIdx, Row, Page: Integer;
  HadView: Boolean;
  OldLeft, OldTop, OldW, OldH, OldCenterX, OldCenterY: Integer;
  RelX, RelY: Double;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) = 0 then Exit;

  HadView := Assigned(FPreviewImage) and Assigned(FPreviewScroll) and
    (FPreviewImage.Width > 0) and (FPreviewImage.Height > 0);
  if HadView then
  begin
    OldLeft := FPreviewImage.Left;
    OldTop := FPreviewImage.Top;
    OldW := FPreviewImage.Width;
    OldH := FPreviewImage.Height;
    OldCenterX := FPreviewScroll.HorzScrollBar.Position +
      FPreviewScroll.ClientWidth div 2 - OldLeft;
    OldCenterY := FPreviewScroll.VertScrollBar.Position +
      FPreviewScroll.ClientHeight div 2 - OldTop;
    RelX := OldCenterX / Max(1, OldW);
    RelY := OldCenterY / Max(1, OldH);
    if RelX < 0 then RelX := 0 else if RelX > 1 then RelX := 1;
    if RelY < 0 then RelY := 0 else if RelY > 1 then RelY := 1;
  end
  else
  begin
    RelX := 0.5;
    RelY := 0.5;
  end;

  FrameIdx := Max(0, Min(FrameIdx, High(FFrames)));
  FPreviewFrameIdx := FrameIdx;
  if (not HadView) and Assigned(FPreviewOneToOne) and FPreviewOneToOne.Checked then
    FPreviewZoomPct := 100
  else if not HadView then
    FPreviewZoomPct := 0;
  StripIdx := FrameLeadStrip(FFrames[FrameIdx], FRollData.LengthLines);
  Row := StripIdx div Max(1, FStripView.StripsPerRow);
  Page := Row div Max(1, FStripView.RowsPerPage);
  FStripView.GotoPage(Page);
  FStripView.SelectFrame(FrameIdx);
  UpdateNavButtons;
  UpdateStatus;
  RenderFramePreview;
  if HadView and Assigned(FPreviewImage) and Assigned(FPreviewScroll) then
  begin
    FPreviewScroll.HorzScrollBar.Position := Max(0,
      FPreviewImage.Left + Round(RelX * FPreviewImage.Width) -
      FPreviewScroll.ClientWidth div 2);
    FPreviewScroll.VertScrollBar.Position := Max(0,
      FPreviewImage.Top + Round(RelY * FPreviewImage.Height) -
      FPreviewScroll.ClientHeight div 2);
  end;
end;

procedure TMainForm.PreviewJumpMarker(Forward: Boolean);
var
  i, TargetIdx: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) = 0 then Exit;
  TargetIdx := -1;

  if Forward then
  begin
    for i := FPreviewFrameIdx + 1 to High(FFrames) do
      if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
    if TargetIdx < 0 then
      for i := 0 to FPreviewFrameIdx do
        if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
  end
  else
  begin
    for i := FPreviewFrameIdx - 1 downto 0 do
      if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
    if TargetIdx < 0 then
      for i := High(FFrames) downto FPreviewFrameIdx do
        if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
  end;

  if TargetIdx >= 0 then PreviewSelectFrame(TargetIdx);
end;

procedure TMainForm.PreviewApplyRotation(Delta: Integer);
var
  Rot: Integer;
begin
  if FChkPerFrame.Checked and FRollData.Loaded and
     (FPreviewFrameIdx >= 0) and (FPreviewFrameIdx <= High(FFrames)) then
  begin
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
    Rot := FFrames[FPreviewFrameIdx].Rotation;
    if not FFrames[FPreviewFrameIdx].HasOverride then
      Rot := CurrentProcessRotation;
    FFrames[FPreviewFrameIdx].Rotation := ((Rot + Delta) mod 360 + 360) mod 360;
    FFrames[FPreviewFrameIdx].FlipH := FChkMirror.Checked;
    FFrames[FPreviewFrameIdx].Negative := FChkNegative.Checked;
    FFrames[FPreviewFrameIdx].HasOverride := True;
    FStripView.UpdateFrames(FFrames);
    MarkDirty;
  end
  else
    SetProcessRotation(CurrentProcessRotation + Delta);

  RenderFramePreview;
end;

procedure TMainForm.PreviewToggleMirror;
begin
  if FChkPerFrame.Checked and FRollData.Loaded and
     (FPreviewFrameIdx >= 0) and (FPreviewFrameIdx <= High(FFrames)) then
  begin
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
    if not FFrames[FPreviewFrameIdx].HasOverride then
      FFrames[FPreviewFrameIdx].Rotation := CurrentProcessRotation;
    FFrames[FPreviewFrameIdx].FlipH := not FFrames[FPreviewFrameIdx].FlipH;
    FFrames[FPreviewFrameIdx].Negative := FChkNegative.Checked;
    FFrames[FPreviewFrameIdx].HasOverride := True;
    FStripView.UpdateFrames(FFrames);
    MarkDirty;
  end
  else
    FChkMirror.Checked := not FChkMirror.Checked;

  RenderFramePreview;
end;

procedure TMainForm.PreviewToggleNegative;
begin
  if FChkPerFrame.Checked and FRollData.Loaded and
     (FPreviewFrameIdx >= 0) and (FPreviewFrameIdx <= High(FFrames)) then
  begin
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
    if not FFrames[FPreviewFrameIdx].HasOverride then
      FFrames[FPreviewFrameIdx].Rotation := CurrentProcessRotation;
    FFrames[FPreviewFrameIdx].FlipH := FChkMirror.Checked;
    FFrames[FPreviewFrameIdx].Negative := not FFrames[FPreviewFrameIdx].Negative;
    FFrames[FPreviewFrameIdx].HasOverride := True;
    FStripView.UpdateFrames(FFrames);
    MarkDirty;
  end
  else
    FChkNegative.Checked := not FChkNegative.Checked;

  RenderFramePreview;
end;

procedure TMainForm.OnPreviewWindowKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  Step: Integer;
begin
  if ssCtrl in Shift then Exit;
  Step := 1;
  if Assigned(FPreviewFrameStep) then
    Step := Max(1, FPreviewFrameStep.Value);
  case Key of
    Ord('X'): begin PreviewSelectFrame(FPreviewFrameIdx - Step); Key := 0; end;
    Ord('C'): begin PreviewSelectFrame(FPreviewFrameIdx + Step); Key := 0; end;
    Ord('G'): begin PreviewJumpMarker(False); Key := 0; end;
    Ord('F'): begin PreviewJumpMarker(True); Key := 0; end;
    Ord('R'): begin PreviewApplyRotation(90); Key := 0; end;
    Ord('M'): begin PreviewToggleMirror; Key := 0; end;
    Ord('N'): begin PreviewToggleNegative; Key := 0; end;
    VK_ESCAPE:
      begin
        if Assigned(FPreviewForm) then FPreviewForm.Close;
        Key := 0;
      end;
  end;
end;

procedure TMainForm.OnPreviewNavButton(Sender: TObject);
var
  Step: Integer;
begin
  if not (Sender is TComponent) then Exit;
  Step := 1;
  if Assigned(FPreviewFrameStep) then
    Step := Max(1, FPreviewFrameStep.Value);
  case TComponent(Sender).Tag of
    1: PreviewSelectFrame(FPreviewFrameIdx - Step);
    2: PreviewSelectFrame(FPreviewFrameIdx + Step);
    3: PreviewJumpMarker(False);
    4: PreviewJumpMarker(True);
  end;
end;

procedure TMainForm.OnPreviewProcessButton(Sender: TObject);
begin
  if not (Sender is TComponent) then Exit;
  case TComponent(Sender).Tag of
    -90: PreviewApplyRotation(-90);
    90: PreviewApplyRotation(90);
    1: PreviewToggleMirror;
    2: PreviewToggleNegative;
  end;
end;

procedure TMainForm.OnPreviewQualityToggle(Sender: TObject);
begin
  if Assigned(FPreviewFullRes) then
    FPreviewKeepFullRes := FPreviewFullRes.Checked;
  if Assigned(FPreviewOneToOne) then
    FPreviewKeepOneToOne := FPreviewOneToOne.Checked;
  if FPreviewKeepOneToOne then
    FPreviewZoomPct := 100
  else
    FPreviewZoomPct := 0;
  RenderFramePreview;
end;

procedure TMainForm.OnPreviewTopMostToggle(Sender: TObject);
begin
  if not Assigned(FPreviewForm) then Exit;
  if Assigned(FPreviewTopMost) then
    FPreviewKeepTopMost := FPreviewTopMost.Checked;
  if FPreviewKeepTopMost then
    FPreviewForm.FormStyle := fsStayOnTop
  else
    FPreviewForm.FormStyle := fsNormal;
end;

procedure TMainForm.OnPreviewMouseWheel(Sender: TObject; Shift: TShiftState;
  WheelDelta: Integer; MousePos: TPoint; var Handled: Boolean);
var
  OldW, OldH, NewW, NewH: Integer;
  OldCenterX, OldCenterY: Integer;
  RelX, RelY: Double;
  Bmp: TBitmap;
begin
  Handled := True;
  if (not Assigned(FPreviewImage)) or (not Assigned(FPreviewScroll)) then Exit;
  if (FPreviewImage.Width <= 0) or (FPreviewImage.Height <= 0) then Exit;
  Bmp := FPreviewImage.Picture.Bitmap;
  if (Bmp = nil) or (Bmp.Width <= 0) or (Bmp.Height <= 0) then Exit;

  OldW := FPreviewImage.Width;
  OldH := FPreviewImage.Height;
  OldCenterX := FPreviewScroll.HorzScrollBar.Position + FPreviewScroll.ClientWidth div 2 - FPreviewImage.Left;
  OldCenterY := FPreviewScroll.VertScrollBar.Position + FPreviewScroll.ClientHeight div 2 - FPreviewImage.Top;
  RelX := OldCenterX / Max(1, OldW);
  RelY := OldCenterY / Max(1, OldH);

  if FPreviewZoomPct <= 0 then
    FPreviewZoomPct := Max(5, Min(1600, Round(OldW * 100.0 / Bmp.Width)));
  if WheelDelta > 0 then
    FPreviewZoomPct := Min(1600, Round(FPreviewZoomPct * 1.25))
  else
    FPreviewZoomPct := Max(5, Round(FPreviewZoomPct / 1.25));

  ApplyPreviewZoom;
  NewW := FPreviewImage.Width;
  NewH := FPreviewImage.Height;
  FPreviewScroll.HorzScrollBar.Position :=
    Max(0, FPreviewImage.Left + Round(RelX * NewW) - FPreviewScroll.ClientWidth div 2);
  FPreviewScroll.VertScrollBar.Position :=
    Max(0, FPreviewImage.Top + Round(RelY * NewH) - FPreviewScroll.ClientHeight div 2);
end;

procedure TMainForm.OnPreviewMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Ctrl: TControl;
begin
  if (Button <> mbMiddle) or (not Assigned(FPreviewScroll)) then Exit;
  if Sender is TControl then
    Ctrl := TControl(Sender)
  else
    Ctrl := FPreviewScroll;

  FPreviewPanning := True;
  FPreviewPanStartMouse := Ctrl.ClientToScreen(Point(X, Y));
  FPreviewPanStartHorz := FPreviewScroll.HorzScrollBar.Position;
  FPreviewPanStartVert := FPreviewScroll.VertScrollBar.Position;
  FPreviewScroll.Cursor := crSizeAll;
  if Assigned(FPreviewImage) then
    FPreviewImage.Cursor := crSizeAll;
end;

procedure TMainForm.OnPreviewMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  Ctrl: TControl;
  ScreenPoint: TPoint;
begin
  if (not FPreviewPanning) or (not Assigned(FPreviewScroll)) then Exit;
  if Sender is TControl then
    Ctrl := TControl(Sender)
  else
    Ctrl := FPreviewScroll;

  ScreenPoint := Ctrl.ClientToScreen(Point(X, Y));
  FPreviewScroll.HorzScrollBar.Position :=
    Max(0, FPreviewPanStartHorz - (ScreenPoint.X - FPreviewPanStartMouse.X));
  FPreviewScroll.VertScrollBar.Position :=
    Max(0, FPreviewPanStartVert - (ScreenPoint.Y - FPreviewPanStartMouse.Y));
end;

procedure TMainForm.OnPreviewMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button <> mbMiddle then Exit;
  FPreviewPanning := False;
  if Assigned(FPreviewScroll) then
    FPreviewScroll.Cursor := crDefault;
  if Assigned(FPreviewImage) then
    FPreviewImage.Cursor := crDefault;
end;

procedure TMainForm.OnPreviewScrollResize(Sender: TObject);
begin
  if FPreviewZoomPct = 0 then
    ApplyPreviewZoom;
end;

procedure TMainForm.OnFrameChanged(Sender: TObject);
{ Called after any drag-resize or drag-move commits a new frame position.
  Syncs main-form stats, marks the QPF dirty, and refreshes the UI. }
begin
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  SortFramesByPosition(FFrames);
  { Sync stats (TStripView already recalculated internally, but FFrameStats
    in TMainForm needs updating too so the Process/Framing tabs stay correct) }
  CalculateFrameStats(FFrames, FFrameStats);
  MarkOversizedUndersized(FFrames, FFrameStats);
  RefreshFrameColors;   { re-evaluates oversize/undersize thresholds + repaints }
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnFormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (ActiveControl is TCustomEdit) then Exit;
  if (ssCtrl in Shift) and (Key = Ord('Z')) then
  begin
    UndoLastFrameChange;
    Key := 0;
    Exit;
  end;
  if (ssCtrl in Shift) and (Key = Ord('A')) then
  begin
    if FRollData.Loaded then
      OnSelectAll(Self);
    Key := 0;
    Exit;
  end;
  if (ssCtrl in Shift) and (Key = Ord('D')) then
  begin
    if FRollData.Loaded then
      OnSelectNone(Self);
    Key := 0;
    Exit;
  end;
  if (ssCtrl in Shift) or (ssAlt in Shift) then Exit;
  if not FRollData.Loaded then Exit;

  case Key of
    Ord('A'):
      begin
        OnMarkFolder(Self);
        Key := 0;
      end;
    Ord('S'):
      begin
        OnSplitFrame(Self);
        Key := 0;
      end;
    Ord('J'):
      begin
        OnCombineSelectedOverlapping(Self);
        Key := 0;
      end;
    Ord('E'):
      begin
        OnMergeAdjacent(Self);
        Key := 0;
      end;
    Ord('C'):
      begin
        OnNext(Self);
        Key := 0;
      end;
    Ord('X'):
      begin
        OnPrev(Self);
        Key := 0;
      end;
    Ord('D'):
      begin
        DeleteSelectedFrames(False);
        Key := 0;
      end;
    Ord('Z'):
      begin
        OnToggleSelectedSuggested(Self);
        Key := 0;
      end;
    Ord('F'):
      begin
        JumpToMarker(True);
        Key := 0;
      end;
    Ord('G'):
      begin
        JumpToMarker(False);
        Key := 0;
      end;
  end;
end;

procedure TMainForm.OnSelectPage(Sender: TObject);   begin FStripView.SelectPage; end;
procedure TMainForm.OnSelectAll(Sender: TObject);    begin FStripView.SelectAll;  end;
procedure TMainForm.OnSelectNone(Sender: TObject);   begin FStripView.SelectNone; end;

procedure TMainForm.OnDeleteSelected(Sender: TObject);
begin
  DeleteSelectedFrames(True);
end;

procedure TMainForm.DeleteSelectedFrames(AskConfirm: Boolean);
var
  i, j: Integer;
  NewFrames: TFrameList;
begin
  if not FRollData.Loaded then Exit;
  if AskConfirm and
     (MessageDlg('Delete selected frames?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  PushFrameUndo;

  NewFrames := nil;
  j := 0;
  for i := 0 to High(FFrames) do
    if not FFrames[i].IsSelected then Inc(j);

  SetLength(NewFrames, j);
  j := 0;
  for i := 0 to High(FFrames) do
    if not FFrames[i].IsSelected then
    begin
      NewFrames[j]       := FFrames[i];
      NewFrames[j].Index := j;
      Inc(j);
    end;

  FFrames := NewFrames;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnDeleteAll(Sender: TObject);
begin
  if not FRollData.Loaded then Exit;
  if MessageDlg('Delete ALL frames?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  PushFrameUndo;
  SetLength(FFrames, 0);
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnFrameFillOpacityChanged(Sender: TObject);
begin
  if Assigned(FLblFrameFillOpacity) and Assigned(FTrackFrameFillOpacity) then
    FLblFrameFillOpacity.Caption := IntToStr(FTrackFrameFillOpacity.Position) + '%';
  if FDraggingVisualSlider then Exit;
  if Assigned(FStripView) and Assigned(FTrackFrameFillOpacity) then
    FStripView.FrameFillOpacity := FTrackFrameFillOpacity.Position;
end;

procedure TMainForm.OnVisualSliderMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
    FDraggingVisualSlider := True;
end;

procedure TMainForm.OnVisualSliderRelease(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
    FDraggingVisualSlider := False;
  if Sender = FTrackFrameFillOpacity then
    OnFrameFillOpacityChanged(Sender)
  else if (Sender = FTrackOversized) or (Sender = FTrackUndersized) then
    OnDetectSizeChanged(Sender);
end;

procedure TMainForm.OnMarkFolder(Sender: TObject);
var
  i: Integer;
  AnyChanged: Boolean;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  AnyChanged := False;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      AnyChanged := True;
  if not AnyChanged then Exit;

  PushFrameUndo;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      FFrames[i].IsMarker := not FFrames[i].IsMarker;
  FStripView.UpdateFrames(FFrames);
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnSuggestMarkers(Sender: TObject);
var
  i, j, n, PositiveCount, SuggestCount, LastSuggestedIdx, CandidateIdx: Integer;
  Direction, AnchorIdx, ClearFromIdx, ClearToIdx: Integer;
  Gaps, SortedGaps: array of Int64;
  MedianGap, Q1Gap, Q3Gap, IQRGap, MedianBased, SpreadBased, PercentileBased,
  Threshold, GapValue: Int64;
  Multiplier, IQRFactor, SensitivityRange, Strictness, Percentile: Double;
  Tmp: Int64;

  function PercentileGap(Pct: Double): Int64;
  var
    Idx: Integer;
  begin
    if PositiveCount <= 0 then Exit(0);
    Idx := Round((PositiveCount - 1) * Pct);
    if Idx < 0 then Idx := 0;
    if Idx >= PositiveCount then Idx := PositiveCount - 1;
    Result := SortedGaps[Idx];
  end;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  SortFramesByPosition(FFrames);
  n := Length(FFrames) - 1;
  if n < 1 then Exit;

  if Sender is TComponent then
    Direction := TComponent(Sender).Tag
  else
    Direction := 0;
  AnchorIdx := -1;
  ClearFromIdx := 0;
  ClearToIdx := High(FFrames);
  if Direction <> 0 then
  begin
    AnchorIdx := GetSingleSelectedFrameIdx;
    if AnchorIdx < 0 then
    begin
      FLblDetectStatus.Caption := 'Select exactly one anchor frame first.';
      ShowMessage('Select exactly one frame as the anchor, then suggest markers toward start or end.');
      Exit;
    end;
    if Direction < 0 then
    begin
      ClearFromIdx := 0;
      ClearToIdx := AnchorIdx - 1;
    end
    else
    begin
      ClearFromIdx := AnchorIdx + 1;
      ClearToIdx := High(FFrames);
    end;
    if ClearFromIdx > ClearToIdx then
    begin
      FLblDetectStatus.Caption := 'No frames in that direction.';
      Exit;
    end;
  end;

  Gaps := nil; SortedGaps := nil;
  SetLength(Gaps, n);
  SetLength(SortedGaps, n);
  PositiveCount := 0;
  for i := 0 to n - 1 do
  begin
    GapValue := FFrames[i + 1].LeadEdge - FFrames[i].TrailEdge;
    if GapValue < 0 then GapValue := 0;
    Gaps[i] := GapValue;
    if GapValue > 0 then
    begin
      SortedGaps[PositiveCount] := GapValue;
      Inc(PositiveCount);
    end;
  end;
  SetLength(SortedGaps, PositiveCount);
  if PositiveCount = 0 then Exit;

  { Insertion sort is fine here; this is one integer per gap, not image data. }
  for i := 1 to PositiveCount - 1 do
  begin
    Tmp := SortedGaps[i];
    j   := i - 1;
    while (j >= 0) and (SortedGaps[j] > Tmp) do
    begin
      SortedGaps[j + 1] := SortedGaps[j];
      Dec(j);
    end;
    SortedGaps[j + 1] := Tmp;
  end;

  MedianGap := PercentileGap(0.50);
  Q1Gap := PercentileGap(0.25);
  Q3Gap := PercentileGap(0.75);
  IQRGap := Q3Gap - Q1Gap;
  SensitivityRange := FTrackSensitivity.Max - FTrackSensitivity.Min;
  if SensitivityRange < 1 then SensitivityRange := 1;
  Strictness := (FTrackSensitivity.Position - FTrackSensitivity.Min) / SensitivityRange;
  if Strictness < 0 then Strictness := 0;
  if Strictness > 1 then Strictness := 1;
  Multiplier := 2.0 + Strictness * 38.0;
  IQRFactor := 1.0 + Strictness * 10.0;
  Percentile := 0.75 + Strictness * 0.24;
  if Percentile > 0.99 then Percentile := 0.99;

  MedianBased := Round(MedianGap * Multiplier);
  if IQRGap < (MedianGap div 2) then
    SpreadBased := Q3Gap + Round((MedianGap div 2) * IQRFactor)
  else
    SpreadBased := Q3Gap + Round(IQRGap * IQRFactor);
  PercentileBased := PercentileGap(Percentile);
  if MedianBased > SpreadBased then
    Threshold := MedianBased
  else
    Threshold := SpreadBased;
  if PercentileBased > Threshold then
    Threshold := PercentileBased;

  for i := ClearFromIdx to ClearToIdx do
    FFrames[i].IsSuggested := False;

  SuggestCount := 0;
  LastSuggestedIdx := -1000000;
  for i := 0 to n - 1 do
    if (Gaps[i] >= Threshold) and (Gaps[i] > 0) then
    begin
      if FFrames[i].IsMarker or FFrames[i + 1].IsMarker then
        Continue;

      if Assigned(FChkSuggestBeforeGap) and FChkSuggestBeforeGap.Checked then
        CandidateIdx := i
      else
        CandidateIdx := i + 1;

      if (CandidateIdx < 0) or (CandidateIdx > High(FFrames)) then
        Continue;
      if Direction < 0 then
      begin
        if CandidateIdx >= AnchorIdx then
          Continue;
      end
      else if Direction > 0 then
      begin
        if CandidateIdx <= AnchorIdx then
          Continue;
      end;
      if (CandidateIdx <= LastSuggestedIdx + 1) then
        Continue;
      if FFrames[CandidateIdx].IsMarker then
        Continue;
      if (CandidateIdx > 0) and FFrames[CandidateIdx - 1].IsMarker then
        Continue;

      FFrames[CandidateIdx].IsSuggested := True;
      LastSuggestedIdx := CandidateIdx;
      Inc(SuggestCount);
    end;

  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
  if Direction < 0 then
    FLblDetectStatus.Caption := Format('Suggested markers toward start: %d   Gap threshold: %d px   Strictness: %d',
      [SuggestCount, Threshold, FTrackSensitivity.Position])
  else if Direction > 0 then
    FLblDetectStatus.Caption := Format('Suggested markers toward end: %d   Gap threshold: %d px   Strictness: %d',
      [SuggestCount, Threshold, FTrackSensitivity.Position])
  else if Assigned(FChkSuggestBeforeGap) and FChkSuggestBeforeGap.Checked then
    FLblDetectStatus.Caption := Format('Suggested markers: %d   Gap threshold: %d px   Strictness: %d   Side: before',
      [SuggestCount, Threshold, FTrackSensitivity.Position])
  else
    FLblDetectStatus.Caption := Format('Suggested markers: %d   Gap threshold: %d px   Strictness: %d   Side: after',
      [SuggestCount, Threshold, FTrackSensitivity.Position]);
end;

procedure TMainForm.OnToggleSelectedSuggested(Sender: TObject);
var
  FrameIdx: Integer;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  FrameIdx := GetSingleSelectedFrameIdx;
  if FrameIdx < 0 then
  begin
    FLblDetectStatus.Caption := 'Select exactly one frame to toggle its suggestion.';
    Exit;
  end;

  PushFrameUndo;
  FFrames[FrameIdx].IsSuggested := not FFrames[FrameIdx].IsSuggested;
  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
  if FFrames[FrameIdx].IsSuggested then
    FLblDetectStatus.Caption := Format('Suggested marker toggled on for frame %d.', [FrameIdx + 1])
  else
    FLblDetectStatus.Caption := Format('Suggested marker toggled off for frame %d.', [FrameIdx + 1]);
end;

procedure TMainForm.OnSuggestSensitivityChanged(Sender: TObject);
var
  i: Integer;
  HadSuggestions: Boolean;
begin
  if Assigned(FLblSuggestSensitivity) and Assigned(FTrackSensitivity) then
    FLblSuggestSensitivity.Caption := IntToStr(FTrackSensitivity.Position);

  if not FRollData.Loaded then Exit;

  HadSuggestions := False;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSuggested then
    begin
      HadSuggestions := True;
      Break;
    end;

  if HadSuggestions then
    OnSuggestMarkers(Sender);
end;

procedure TMainForm.OnClearSuggested(Sender: TObject);
var
  i: Integer;
  HadSuggestions: Boolean;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  HadSuggestions := False;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSuggested then
    begin
      FFrames[i].IsSuggested := False;
      HadSuggestions := True;
    end;

  if not HadSuggestions then Exit;

  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
  FLblDetectStatus.Caption := 'Marker suggestions cleared.';
end;

procedure TMainForm.OnClearSelectedSuggested(Sender: TObject);
var
  i, ClearedCount: Integer;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  PushFrameUndo;
  ClearedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected and FFrames[i].IsSuggested then
    begin
      FFrames[i].IsSuggested := False;
      Inc(ClearedCount);
    end;

  if ClearedCount = 0 then
  begin
    FLblDetectStatus.Caption := 'No selected suggested markers to clear.';
    Exit;
  end;

  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
  FLblDetectStatus.Caption := Format('Cleared %d selected suggestion(s).', [ClearedCount]);
end;

procedure TMainForm.OnClearSuggestedEvery(Sender: TObject);
var
  AnchorIdx, Direction, N, i, SeenCount, ClearedCount: Integer;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  AnchorIdx := GetSingleSelectedFrameIdx;
  if AnchorIdx < 0 then
  begin
    FLblDetectStatus.Caption := 'Select exactly one anchor frame first.';
    ShowMessage('Select exactly one frame as the anchor, then run suggested cleanup.');
    Exit;
  end;

  if Sender is TComponent then
    Direction := TComponent(Sender).Tag
  else
    Direction := 1;
  if Direction = 0 then Direction := 1;

  N := Max(1, FSpinSuggestClearEvery.Value);
  SeenCount := 0;
  ClearedCount := 0;

  i := AnchorIdx + Direction;
  while (i >= 0) and (i <= High(FFrames)) do
  begin
    if FFrames[i].IsSuggested then
    begin
      Inc(SeenCount);
      if (SeenCount mod N) = 0 then
      begin
        FFrames[i].IsSuggested := False;
        Inc(ClearedCount);
      end;
    end;
    Inc(i, Direction);
  end;

  if ClearedCount = 0 then
  begin
    FLblDetectStatus.Caption := 'No suggested markers matched cleanup.';
    Exit;
  end;

  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
  if Direction < 0 then
    FLblDetectStatus.Caption := Format('Cleared %d suggested marker(s), every %d toward start.',
      [ClearedCount, N])
  else
    FLblDetectStatus.Caption := Format('Cleared %d suggested marker(s), every %d toward end.',
      [ClearedCount, N]);
end;

procedure TMainForm.OnClearMarkers(Sender: TObject);
var
  i, ClearedCount: Integer;
begin
  if not FRollData.Loaded then Exit;
  if MessageDlg('Clear ALL yellow folder markers?', mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  ClearedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsMarker then
      Inc(ClearedCount);

  if ClearedCount = 0 then
  begin
    FLblDetectStatus.Caption := 'No yellow markers to clear.';
    Exit;
  end;

  PushFrameUndo;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsMarker then
      FFrames[i].IsMarker := False;

  FStripView.UpdateFrames(FFrames);
  MarkDirty;
  UpdateStatus;
  FLblDetectStatus.Caption := Format('Cleared %d yellow marker(s).', [ClearedCount]);
end;

procedure TMainForm.OnClearMarkersDirection(Sender: TObject);
var
  AnchorIdx, Direction, i, ClearedCount: Integer;
begin
  if not FRollData.Loaded then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  AnchorIdx := GetSingleSelectedFrameIdx;
  if AnchorIdx < 0 then
  begin
    FLblDetectStatus.Caption := 'Select exactly one anchor frame first.';
    ShowMessage('Select exactly one frame as the anchor, then clear yellow markers toward start or end.');
    Exit;
  end;

  if Sender is TComponent then
    Direction := TComponent(Sender).Tag
  else
    Direction := 1;
  if Direction = 0 then Direction := 1;

  ClearedCount := 0;
  i := AnchorIdx + Direction;
  while (i >= 0) and (i <= High(FFrames)) do
  begin
    if FFrames[i].IsMarker then
      Inc(ClearedCount);
    Inc(i, Direction);
  end;

  if ClearedCount = 0 then
  begin
    FLblDetectStatus.Caption := 'No yellow markers found in that direction.';
    Exit;
  end;

  PushFrameUndo;
  i := AnchorIdx + Direction;
  while (i >= 0) and (i <= High(FFrames)) do
  begin
    if FFrames[i].IsMarker then
      FFrames[i].IsMarker := False;
    Inc(i, Direction);
  end;

  FStripView.UpdateFrames(FFrames);
  MarkDirty;
  UpdateStatus;
  if Direction < 0 then
    FLblDetectStatus.Caption := Format('Cleared %d yellow marker(s) toward start.', [ClearedCount])
  else
    FLblDetectStatus.Caption := Format('Cleared %d yellow marker(s) toward end.', [ClearedCount]);
end;

procedure TMainForm.OnRotateToggle(Sender: TObject);
begin
  FStripView.RotateCW := not FStripView.RotateCW;
  if FStripView.RotateCW then
    FBtnRotate.Caption := 'Rot CW'
  else
    FBtnRotate.Caption := 'Rot CCW';
end;

{ ── Frame colour refresh ── }

procedure TMainForm.RefreshFrameColors;
begin
  if not FRollData.Loaded then Exit;
  SortFramesByPosition(FFrames);
  { Update thresholds from sliders; unchecked = threshold disabled (huge/tiny value) }
  if FChkShowOversized.Checked then
    FFrameStats.OversizeThreshold  := 1.0 + FTrackOversized.Position  / 100.0
  else
    FFrameStats.OversizeThreshold  := 9999.0;
  if FChkShowUndersized.Checked then
    FFrameStats.UndersizeThreshold := 1.0 - FTrackUndersized.Position / 100.0
  else
    FFrameStats.UndersizeThreshold := 0.0;
  MarkOversizedUndersized(FFrames, FFrameStats);
  FStripView.UpdateFrames(FFrames);
end;

{ ── Frame array helper ── }

procedure TMainForm.DeleteFrameAt(Idx: Integer);
var
  i: Integer;
begin
  for i := Idx to High(FFrames) - 1 do
  begin
    FFrames[i]       := FFrames[i + 1];
    FFrames[i].Index := i;
  end;
  SetLength(FFrames, Length(FFrames) - 1);
end;

{ ── Process tab handlers ── }

procedure TMainForm.OnPerFrameToggle(Sender: TObject);
begin
  FBtnClearOverride.Enabled := True;
  if Assigned(FBtnClearSelectedOverride) then
    FBtnClearSelectedOverride.Enabled := True;
  UpdateSelectedAdjustmentStatus;
end;

procedure TMainForm.OnClearPerFrameOverrides(Sender: TObject);
var
  i: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  for i := 0 to High(FFrames) do
  begin
    FFrames[i].HasOverride      := False;
    FFrames[i].Rotation         := 0;
    FFrames[i].FlipH            := False;
    FFrames[i].Negative         := False;
    FFrames[i].PerFrameBrightness := -1;
    FFrames[i].PerFrameContrast   := -1;
    FFrames[i].PerFrameGamma      := -1;
    FFrames[i].CustomBrightness := -1;
    FFrames[i].CustomContrast   := -1;
    FFrames[i].CustomGamma      := -1;
  end;
  FStripView.UpdateFrames(FFrames);
  RefreshFrameColors;
  MarkDirty;
  UpdateStatus;
  UpdateSelectedAdjustmentStatus;
  ShowMessage('All per-frame overrides cleared.');
end;

procedure TMainForm.OnClearSelectedPerFrameOverrides(Sender: TObject);
var
  i, Cleared: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  Cleared := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
    begin
      FFrames[i].HasOverride      := False;
      FFrames[i].Rotation         := 0;
      FFrames[i].FlipH            := False;
      FFrames[i].Negative         := False;
      FFrames[i].PerFrameBrightness := -1;
      FFrames[i].PerFrameContrast   := -1;
      FFrames[i].PerFrameGamma      := -1;
      FFrames[i].CustomBrightness := -1;
      FFrames[i].CustomContrast   := -1;
      FFrames[i].CustomGamma      := -1;
      Inc(Cleared);
    end;
  if Cleared = 0 then
  begin
    ShowMessage('Select one or more frames first.');
    Exit;
  end;
  FStripView.UpdateFrames(FFrames);
  RefreshFrameColors;
  MarkDirty;
  UpdateStatus;
  UpdateSelectedAdjustmentStatus;
  ShowMessage(Format('Cleared per-frame overrides on %d selected frame(s).', [Cleared]));
end;

procedure TMainForm.OnRotationChanged(Sender: TObject);
var
  Rot, i: Integer;
begin
  if FUpdatingAdjustments then Exit;
  { In per-frame mode apply to selected frames; otherwise just a global setting
    that will be read at export time }
  if not FChkPerFrame.Checked then
  begin
    if Assigned(FPreviewImage) then
      RenderFramePreview;
    Exit;
  end;
  if not FRollData.Loaded     then Exit;
  if FRbRotM90.Checked  then Rot := 270
  else if FRbRot90.Checked  then Rot := 90
  else if FRbRot180.Checked then Rot := 180
  else                           Rot := 0;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
    begin
      FFrames[i].Rotation    := Rot;
      FFrames[i].FlipH       := FChkMirror.Checked;
      FFrames[i].Negative    := FChkNegative.Checked;
      FFrames[i].HasOverride := True;
    end;
  FStripView.UpdateFrames(FFrames);
  RefreshFrameColors;
  MarkDirty;
  UpdateStatus;
  UpdateSelectedAdjustmentStatus;
  if Assigned(FPreviewImage) then
    RenderFramePreview;
end;

{ ── Framing tab – size detection handlers ── }

procedure TMainForm.OnScanDefaults(Sender: TObject);
var
  GammaValue: Integer;
begin
  FUpdatingAdjustments := True;
  try
  if Assigned(FComboAdjustMethod) and (FComboAdjustMethod.ItemIndex = 1) then
  begin
    FTrackContrast.Position := 64;
    FTrackBrightness.Position := 0;
    FTrackGamma.Position := 0;
    FSpinContrast.Value := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value := FTrackGamma.Position;
    Exit;
  end;

  if Assigned(FComboAdjustMethod) and (FComboAdjustMethod.ItemIndex in [2, 3]) then
  begin
    FTrackContrast.Position := 0;
    FTrackBrightness.Position := 0;
    FTrackGamma.Position := 100;
    FSpinContrast.Value := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value := FTrackGamma.Position;
    Exit;
  end;

  if Assigned(FComboAdjustMethod) and (FComboAdjustMethod.ItemIndex = 4) then
  begin
    FTrackContrast.Position := 64;
    FTrackBrightness.Position := 0;
    FTrackGamma.Position := 0;
    FSpinContrast.Value := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value := FTrackGamma.Position;
    Exit;
  end;

  FTrackContrast.Position   := Max(FTrackContrast.Min, Min(FTrackContrast.Max, FRollData.SoftwareContrast));
  FTrackBrightness.Position := Max(FTrackBrightness.Min, Min(FTrackBrightness.Max, FRollData.SoftwareBrightness));
  if FRollData.SoftwareGamma = 0 then
    GammaValue := 100
  else
    GammaValue := FRollData.SoftwareGamma;
  FTrackGamma.Position := Max(FTrackGamma.Min, Min(FTrackGamma.Max, GammaValue));
  FSpinContrast.Value   := FTrackContrast.Position;
  FSpinBrightness.Value := FTrackBrightness.Position;
  FSpinGamma.Value      := FTrackGamma.Position;
  finally
    FUpdatingAdjustments := False;
  end;
end;

procedure TMainForm.OnAdjustmentMethodChanged(Sender: TObject);
begin
  if not Assigned(FComboAdjustMethod) then Exit;

  FUpdatingAdjustments := True;
  try
    if FComboAdjustMethod.ItemIndex = 1 then
    begin
      FTrackContrast.Min := -128;
      FTrackContrast.Max := 255;
      FSpinContrast.MinValue := -128;
      FSpinContrast.MaxValue := 255;

      FTrackBrightness.Min := -128;
      FTrackBrightness.Max := 127;
      FSpinBrightness.MinValue := -128;
      FSpinBrightness.MaxValue := 127;

      FTrackGamma.Min := -255;
      FTrackGamma.Max := 255;
      FSpinGamma.MinValue := -255;
      FSpinGamma.MaxValue := 255;

      FTrackContrast.Position := 64;
      FTrackBrightness.Position := 0;
      FTrackGamma.Position := 0;
    end
    else if FComboAdjustMethod.ItemIndex in [2, 3] then
    begin
      FTrackContrast.Min := -100;
      FTrackContrast.Max := 100;
      FSpinContrast.MinValue := -100;
      FSpinContrast.MaxValue := 100;

      FTrackBrightness.Min := -100;
      FTrackBrightness.Max := 100;
      FSpinBrightness.MinValue := -100;
      FSpinBrightness.MaxValue := 100;

      FTrackGamma.Min := 10;
      FTrackGamma.Max := 300;
      FSpinGamma.MinValue := 10;
      FSpinGamma.MaxValue := 300;

      FTrackContrast.Position := 0;
      FTrackBrightness.Position := 0;
      FTrackGamma.Position := 100;
    end
    else if FComboAdjustMethod.ItemIndex = 4 then
    begin
      FTrackContrast.Min := -128;
      FTrackContrast.Max := 255;
      FSpinContrast.MinValue := -128;
      FSpinContrast.MaxValue := 255;

      FTrackBrightness.Min := -128;
      FTrackBrightness.Max := 127;
      FSpinBrightness.MinValue := -128;
      FSpinBrightness.MaxValue := 127;

      FTrackGamma.Min := -255;
      FTrackGamma.Max := 255;
      FSpinGamma.MinValue := -255;
      FSpinGamma.MaxValue := 255;

      FTrackContrast.Position := 64;
      FTrackBrightness.Position := 0;
      FTrackGamma.Position := 0;
    end
    else
    begin
      FTrackContrast.Min := -100;
      FTrackContrast.Max := 100;
      FSpinContrast.MinValue := -100;
      FSpinContrast.MaxValue := 100;

      FTrackBrightness.Min := -100;
      FTrackBrightness.Max := 100;
      FSpinBrightness.MinValue := -100;
      FSpinBrightness.MaxValue := 100;

      FTrackGamma.Min := 10;
      FTrackGamma.Max := 300;
      FSpinGamma.MinValue := 10;
      FSpinGamma.MaxValue := 300;

      FTrackContrast.Position := 0;
      FTrackBrightness.Position := 0;
      FTrackGamma.Position := 100;
    end;

    FSpinContrast.Value := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value := FTrackGamma.Position;
  finally
    FUpdatingAdjustments := False;
  end;

  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnAdjustmentOptionChanged(Sender: TObject);
begin
  if FUpdatingAdjustments then Exit;
  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnAdjustmentSliderChanged(Sender: TObject);
begin
  if FUpdatingAdjustments then Exit;
  FUpdatingAdjustments := True;
  try
    FSpinContrast.Value   := FTrackContrast.Position;
    FSpinBrightness.Value := FTrackBrightness.Position;
    FSpinGamma.Value      := FTrackGamma.Position;
  finally
    FUpdatingAdjustments := False;
  end;
end;

procedure TMainForm.OnAdjustmentSliderMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
    FDraggingAdjustmentSlider := True;
end;

procedure TMainForm.OnAdjustmentSliderRelease(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
    FDraggingAdjustmentSlider := False;
  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnAdjustmentSliderKeyUp(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    FDraggingAdjustmentSlider := False;
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnAdjustmentSpinChanged(Sender: TObject);
begin
  if FUpdatingAdjustments then Exit;
  FUpdatingAdjustments := True;
  try
    FTrackContrast.Position   := FSpinContrast.Value;
    FTrackBrightness.Position := FSpinBrightness.Value;
    FTrackGamma.Position      := FSpinGamma.Value;
  finally
    FUpdatingAdjustments := False;
  end;
  if FDraggingAdjustmentSlider then Exit;
  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnPreviewAdjustmentChanged(Sender: TObject);
begin
  if not FRollData.Loaded then Exit;
  if not FChkAdjustPreview.Checked then Exit;
  if Assigned(FChkPerFrame) then
  begin
    if FChkPerFrame.Checked then
    begin
      ApplyAdjustmentControlsToSelectedFrames;
      if Assigned(FPreviewImage) then
        RenderFramePreview;
      Exit;
    end;
  end;
  StoreAdjustmentControlsToRoll;
  FStripView.SetPreviewAdjustment(FTrackContrast.Position,
                                  FTrackBrightness.Position,
                                  FTrackGamma.Position,
                                  FComboAdjustMethod.ItemIndex,
                                  CurrentAdjustmentFlags);
  if Assigned(FPreviewImage) then
    RenderFramePreview;
end;

procedure TMainForm.OnAdjustPreviewToggle(Sender: TObject);
begin
  FBtnApplyPreview.Enabled := FChkAdjustPreview.Checked;
  if not FRollData.Loaded then Exit;

  if FChkAdjustPreview.Checked then
  begin
    OnPreviewAdjustmentChanged(Self);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end
  else
  begin
    FStripView.SetPreviewAdjustment(0, 0, 100, 0, 0);
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnSharpnessChanged(Sender: TObject);
begin
  if FUpdatingAdjustments then Exit;
  FUpdatingAdjustments := True;
  try
    if Sender = FTrackSharpness then
      FSpinSharpness.Value := FTrackSharpness.Position
    else if Sender = FSpinSharpness then
      FTrackSharpness.Position := FSpinSharpness.Value;
  finally
    FUpdatingAdjustments := False;
  end;

  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    StoreAdjustmentControlsToRoll;
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnSharpnessModeChanged(Sender: TObject);
begin
  if Assigned(FChkAdjustPreview) and FChkAdjustPreview.Checked then
  begin
    StoreAdjustmentControlsToRoll;
    if Assigned(FPreviewImage) then RenderFramePreview;
  end;
end;

procedure TMainForm.OnAutoAdjustSelected(Sender: TObject);
begin
  AutoAdjustSelectedFrames;
end;

procedure TMainForm.OnDetectSizeChanged(Sender: TObject);
begin
  FLblOverPct.Caption  := IntToStr(FTrackOversized.Position);
  FLblUnderPct.Caption := IntToStr(FTrackUndersized.Position);
  if FDraggingVisualSlider then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  RefreshFrameColors;
end;

procedure TMainForm.OnSelectBySize(Sender: TObject);
var
  i: Integer;
  WantOversized, WantUndersized: Boolean;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  RefreshFrameColors;
  WantOversized := FChkShowOversized.Checked;
  WantUndersized := FChkShowUndersized.Checked;
  for i := 0 to High(FFrames) do
    FFrames[i].IsSelected :=
      (WantOversized and FFrames[i].IsOversized) or
      (WantUndersized and FFrames[i].IsUndersized);
  FStripView.UpdateFrames(FFrames);
  UpdateStatus;
end;

procedure TMainForm.OnJumpAttentionFrame(Sender: TObject);
var
  Mode, StartIdx, Offset, Idx, i, StripIdx, PageSize, PageIdx: Integer;
  Match: Boolean;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) = 0 then Exit;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;

  Mode := 0;
  if Sender is TComponent then
    Mode := TComponent(Sender).Tag;
  StartIdx := GetSingleSelectedFrameIdx;
  if StartIdx < 0 then StartIdx := -1;

  for Offset := 1 to Length(FFrames) do
  begin
    Idx := (StartIdx + Offset) mod Length(FFrames);
    Match := False;
    case Mode of
      -1: Match := FFrames[Idx].IsUndersized;
       1: Match := FFrames[Idx].IsOversized;
    else
      Match := FFrames[Idx].IsOversized or FFrames[Idx].IsUndersized;
    end;
    if Match then
    begin
      for i := 0 to High(FFrames) do
        FFrames[i].IsSelected := (i = Idx);
      FStripView.UpdateFrames(FFrames);
      StripIdx := FrameLeadStrip(FFrames[Idx], FRollData.LengthLines);
      PageSize := Max(1, FStripView.StripsPerRow * Max(1, FStripView.RowsPerPage));
      PageIdx := StripIdx div PageSize;
      FStripView.GotoPage(PageIdx);
      UpdateNavButtons;
      UpdateStatus;
      FStatusBar.SimpleText := Format('Selected attention frame %d.', [Idx + 1]);
      Exit;
    end;
  end;

  case Mode of
    -1: ShowMessage('No smaller-than-threshold frame found.');
     1: ShowMessage('No bigger-than-threshold frame found.');
  else
    ShowMessage('No red/flagged frame found.');
  end;
end;

{ ── Framing tab – overlap / merge handlers ── }

procedure TMainForm.OnCombineOverlapping(Sender: TObject);
var
  i, j: Integer;
  AnyChanged: Boolean;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) < 2 then Exit;
  PushFrameUndo;
  repeat
    AnyChanged := False;
    i := 0;
    while i <= High(FFrames) - 1 do
    begin
      j := i + 1;
      while j <= High(FFrames) do
      begin
        if (FFrames[i].LeadEdge < FFrames[j].TrailEdge) and
           (FFrames[i].TrailEdge > FFrames[j].LeadEdge) then
        begin
          FFrames[i].LeadEdge  := Min(FFrames[i].LeadEdge,  FFrames[j].LeadEdge);
          FFrames[i].TrailEdge := Max(FFrames[i].TrailEdge, FFrames[j].TrailEdge);
          FFrames[i].LeftEdge  := Min(FFrames[i].LeftEdge,  FFrames[j].LeftEdge);
          FFrames[i].RightEdge := Max(FFrames[i].RightEdge, FFrames[j].RightEdge);
          DeleteFrameAt(j);
          AnyChanged := True;
        end
        else
          Inc(j);
      end;
      Inc(i);
    end;
  until not AnyChanged;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnCombineSelectedOverlapping(Sender: TObject);
var
  i, j: Integer;
  AnyChanged: Boolean;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) < 2 then Exit;
  PushFrameUndo;
  repeat
    AnyChanged := False;
    i := 0;
    while i <= High(FFrames) - 1 do
    begin
      if not FFrames[i].IsSelected then begin Inc(i); Continue; end;
      j := i + 1;
      while j <= High(FFrames) do
      begin
        if FFrames[j].IsSelected and
           (FFrames[i].LeadEdge < FFrames[j].TrailEdge) and
           (FFrames[i].TrailEdge > FFrames[j].LeadEdge) then
        begin
          FFrames[i].LeadEdge  := Min(FFrames[i].LeadEdge,  FFrames[j].LeadEdge);
          FFrames[i].TrailEdge := Max(FFrames[i].TrailEdge, FFrames[j].TrailEdge);
          FFrames[i].LeftEdge  := Min(FFrames[i].LeftEdge,  FFrames[j].LeftEdge);
          FFrames[i].RightEdge := Max(FFrames[i].RightEdge, FFrames[j].RightEdge);
          DeleteFrameAt(j);
          AnyChanged := True;
        end
        else
          Inc(j);
      end;
      Inc(i);
    end;
  until not AnyChanged;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnMergeAdjacent(Sender: TObject);
var
  SelIdx: array of Integer;
  Count, k, A, B: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  { Collect selected indices in ascending order }
  SetLength(SelIdx, 0);
  for k := 0 to High(FFrames) do
    if FFrames[k].IsSelected then
    begin
      SetLength(SelIdx, Length(SelIdx) + 1);
      SelIdx[High(SelIdx)] := k;
    end;
  Count := Length(SelIdx);
  if Count < 2 then Exit;
  PushFrameUndo;
  { Process pairs from RIGHT to LEFT so deletions do not shift lower indices.
    Pairs: (SelIdx[0],SelIdx[1]), (SelIdx[2],SelIdx[3]), ...
    For each pair merge B into A, then delete B (B > A always). }
  k := Count div 2 - 1;          // index of last complete pair (0-based)
  while k >= 0 do
  begin
    A := SelIdx[k * 2];
    B := SelIdx[k * 2 + 1];
    FFrames[A].LeadEdge  := Min(FFrames[A].LeadEdge,  FFrames[B].LeadEdge);
    FFrames[A].TrailEdge := Max(FFrames[A].TrailEdge, FFrames[B].TrailEdge);
    FFrames[A].LeftEdge  := Min(FFrames[A].LeftEdge,  FFrames[B].LeftEdge);
    FFrames[A].RightEdge := Max(FFrames[A].RightEdge, FFrames[B].RightEdge);
    FFrames[A].IsSelected := True;
    DeleteFrameAt(B);
    Dec(k);
  end;
  { Re-index }
  for k := 0 to High(FFrames) do FFrames[k].Index := k;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnJoinCloseSelected(Sender: TObject);
var
  i, j, k: Integer;
  GapLimit: Int64;
  MergedFrame: TFrameRecord;
  NewFrames: TFrameList;
  MergedRuns, RemovedCount, SelectedCount: Integer;

  procedure AppendFrame(const AFrame: TFrameRecord);
  begin
    SetLength(NewFrames, Length(NewFrames) + 1);
    NewFrames[High(NewFrames)] := AFrame;
  end;

begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) < 2 then Exit;

  SelectedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      Inc(SelectedCount);
  if SelectedCount < 2 then
  begin
    ShowMessage('Select two or more neighboring frame fragments to join.');
    Exit;
  end;

  GapLimit := 0;
  if Assigned(FSpinJoinGap) then
    GapLimit := FSpinJoinGap.Value;

  NewFrames := nil;
  MergedRuns := 0;
  RemovedCount := 0;
  i := 0;
  while i <= High(FFrames) do
  begin
    if not FFrames[i].IsSelected then
    begin
      AppendFrame(FFrames[i]);
      Inc(i);
      Continue;
    end;

    MergedFrame := FFrames[i];
    j := i + 1;
    while (j <= High(FFrames)) and FFrames[j].IsSelected and
          (FFrames[j].LeadEdge - MergedFrame.TrailEdge <= GapLimit) do
    begin
      MergedFrame.LeadEdge  := Min(MergedFrame.LeadEdge,  FFrames[j].LeadEdge);
      MergedFrame.TrailEdge := Max(MergedFrame.TrailEdge, FFrames[j].TrailEdge);
      MergedFrame.LeftEdge  := Min(MergedFrame.LeftEdge,  FFrames[j].LeftEdge);
      MergedFrame.RightEdge := Max(MergedFrame.RightEdge, FFrames[j].RightEdge);
      MergedFrame.IsMarker  := MergedFrame.IsMarker or FFrames[j].IsMarker;
      MergedFrame.IsSuggested := MergedFrame.IsSuggested or FFrames[j].IsSuggested;
      MergedFrame.IsExported := MergedFrame.IsExported and FFrames[j].IsExported;
      Inc(RemovedCount);
      Inc(j);
    end;

    if j > i + 1 then
      Inc(MergedRuns);
    MergedFrame.IsSelected := True;
    AppendFrame(MergedFrame);
    i := j;
  end;

  if RemovedCount = 0 then
  begin
    ShowMessage('No selected neighboring frames were close enough to join.');
    Exit;
  end;

  PushFrameUndo;
  for k := 0 to High(NewFrames) do
    NewFrames[k].Index := k;
  FFrames := NewFrames;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  FStatusBar.SimpleText := Format('Joined %d selected fragment group(s); removed %d split frame(s).',
                                  [MergedRuns, RemovedCount]);
end;

procedure TMainForm.OnCloseSelectedGaps(Sender: TObject);
var
  i, ChangedCount, SelectedCount: Integer;
  MidLine: Int64;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  SortFramesByPosition(FFrames);

  SelectedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      Inc(SelectedCount);
  if SelectedCount < 2 then
  begin
    ShowMessage('Select two or more neighboring frames to close gaps.');
    Exit;
  end;

  ChangedCount := 0;
  for i := 0 to High(FFrames) - 1 do
  begin
    if FFrames[i].IsSelected and FFrames[i + 1].IsSelected and
       (FFrames[i].TrailEdge < FFrames[i + 1].LeadEdge) then
      Inc(ChangedCount);
  end;
  if ChangedCount = 0 then
  begin
    ShowMessage('No positive gaps found between neighboring selected frames.');
    Exit;
  end;

  PushFrameUndo;
  for i := 0 to High(FFrames) - 1 do
  begin
    if FFrames[i].IsSelected and FFrames[i + 1].IsSelected and
       (FFrames[i].TrailEdge < FFrames[i + 1].LeadEdge) then
    begin
      MidLine := (FFrames[i].TrailEdge + FFrames[i + 1].LeadEdge) div 2;
      FFrames[i].TrailEdge := MidLine;
      FFrames[i + 1].LeadEdge := MidLine;
    end;
  end;

  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  FStatusBar.SimpleText := Format('Closed %d selected frame gap(s).', [ChangedCount]);
end;

procedure TMainForm.OnExpandSelected(Sender: TObject);
var
  i, ChangedCount, SelectedCount: Integer;
  AddTop, AddBottom, AddLeft, AddRight: Integer;
  MaxLine, NewLead, NewTrail: Int64;
  NewLeft, NewRight: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));

  AddTop := 0;
  AddBottom := 0;
  AddLeft := 0;
  AddRight := 0;
  if Assigned(FSpinExpandTop) then AddTop := FSpinExpandTop.Value;
  if Assigned(FSpinExpandBottom) then AddBottom := FSpinExpandBottom.Value;
  if Assigned(FSpinExpandLeft) then AddLeft := FSpinExpandLeft.Value;
  if Assigned(FSpinExpandRight) then AddRight := FSpinExpandRight.Value;
  if (AddTop = 0) and (AddBottom = 0) and (AddLeft = 0) and (AddRight = 0) then Exit;

  SelectedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      Inc(SelectedCount);
  if SelectedCount = 0 then
  begin
    ShowMessage('No selected frames to expand.');
    Exit;
  end;

  PushFrameUndo;
  ChangedCount := 0;
  MaxLine := Int64(Max(1, FRollData.StripCount)) * Int64(Max(1, FRollData.LengthLines));
  for i := 0 to High(FFrames) do
  begin
    if not FFrames[i].IsSelected then Continue;

    NewLead := FFrames[i].LeadEdge - Int64(AddTop);
    NewTrail := FFrames[i].TrailEdge + Int64(AddBottom);
    NewLead := Max(Int64(0), Min(MaxLine - 1, NewLead));
    NewTrail := Max(NewLead + 1, Min(MaxLine, NewTrail));

    NewLeft := FFrames[i].LeftEdge - AddLeft;
    NewRight := FFrames[i].RightEdge + AddRight;
    NewLeft := Max(0, Min(Max(0, FRollData.WidthPixels - 1), NewLeft));
    NewRight := Max(NewLeft + 1, Min(FRollData.WidthPixels, NewRight));

    FFrames[i].LeadEdge := NewLead;
    FFrames[i].TrailEdge := NewTrail;
    FFrames[i].LeftEdge := NewLeft;
    FFrames[i].RightEdge := NewRight;
    Inc(ChangedCount);
  end;

  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  FStatusBar.SimpleText := Format('Expanded %d selected frame(s).', [ChangedCount]);
end;

{ ── Trim handlers ────────────────────────────────────────────────────────── }

procedure TMainForm.OnTrimToggle(Sender: TObject);
begin
  FStripView.TrimEnabled := FChkTrimEnable.Checked;
  FStripView.Invalidate;
end;

procedure TMainForm.OnTrimSpinChanged(Sender: TObject);
begin
  FStripView.TrimTopPx    := FSpinTrimTop.Value;
  FStripView.TrimBottomPx := FSpinTrimBottom.Value;
  if FStripView.TrimEnabled then FStripView.Invalidate;
end;

procedure TMainForm.OnTrimViewChanged(Sender: TObject);
{ FStripView fired OnTrimChanged because the user dragged a trim line.
  Sync the spinedits so they reflect the new values. }
begin
  FSpinTrimTop.OnChange    := nil;    { suppress re-entrant OnTrimSpinChanged }
  FSpinTrimBottom.OnChange := nil;
  FSpinTrimTop.Value    := FStripView.TrimTopPx;
  FSpinTrimBottom.Value := FStripView.TrimBottomPx;
  FSpinTrimTop.OnChange    := @OnTrimSpinChanged;
  FSpinTrimBottom.OnChange := @OnTrimSpinChanged;
end;

procedure TMainForm.OnApplyTrim(Sender: TObject);
{ Clip frame edges to the trim lines.
  The trim lines are absolute positions on the film-width axis:
    topLimit = FTrimTopPx from the LeftEdge=0 side
    botLimit = WidthPixels - FTrimBottomPx from the LeftEdge=0 side
  A frame's LeftEdge is moved to topLimit only if it currently sits above
  (less than) topLimit.  Its RightEdge is moved to botLimit only if it
  currently extends below (greater than) botLimit.  Frames already inside
  the trim zone are untouched. }
var
  i: Integer;
  topPx, botPx: Integer;
  topLimit, botLimit: Integer;
begin
  if not FRollData.Loaded then Exit;
  topPx := FSpinTrimTop.Value;
  botPx := FSpinTrimBottom.Value;
  if (topPx = 0) and (botPx = 0) then Exit;

  { Absolute film-pixel positions of each trim line }
  topLimit := topPx;
  botLimit := FRollData.WidthPixels - botPx;

  if MessageDlg(Format(
       'Clip ALL %d frames to trim lines?'#13#10 +
       '  Top edge clamped at: %d px from film edge'#13#10 +
       '  Bottom edge clamped at: %d px from film edge'#13#10#13#10 +
       'Only frames that extend past a trim line are affected.',
        [Length(FFrames), topLimit, botLimit]),
     mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  PushFrameUndo;

  for i := 0 to High(FFrames) do
  begin
    { Clip top edge: move LeftEdge down to the trim line if it sticks out above }
    if (topPx > 0) and (FFrames[i].LeftEdge < topLimit) then
      FFrames[i].LeftEdge := topLimit;

    { Clip bottom edge: move RightEdge up to the trim line if it sticks out below }
    if (botPx > 0) and (FFrames[i].RightEdge > botLimit) then
      FFrames[i].RightEdge := botLimit;

    { Guard: if a frame ends up fully outside the kept zone, collapse it minimally }
    if FFrames[i].LeftEdge >= FFrames[i].RightEdge then
      FFrames[i].RightEdge := FFrames[i].LeftEdge + 1;
  end;

  { Reset trim controls — overlay cleared after apply }
  FSpinTrimTop.Value    := 0;
  FSpinTrimBottom.Value := 0;
  FStripView.TrimTopPx    := 0;
  FStripView.TrimBottomPx := 0;

  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnSelectSuggested(Sender: TObject);
var
  i: Integer;
  Found: Boolean;
begin
  if not FRollData.Loaded then Exit;
  Found := False;
  for i := 0 to High(FFrames) do
  begin
    if FFrames[i].IsSuggested then
    begin
      FFrames[i].IsSelected := True;
      Found := True;
    end
    else
      FFrames[i].IsSelected := False;
  end;
  if not Found then
    ShowMessage('No suggested folder-start markers found.');
  if Assigned(FStripView) then
    FStripView.UpdateFrames(FFrames);
  UpdateStatus;
end;

procedure TMainForm.OnSplitPreviewChanged(Sender: TObject);
begin
  if not Assigned(FStripView) then Exit;
  if Assigned(FSpinSplitN) then
    FStripView.SplitPreviewParts := FSpinSplitN.Value;
  if Assigned(FChkSplitPreview) then
    FStripView.SplitPreviewEnabled := FChkSplitPreview.Checked;
end;

procedure TMainForm.OnSplitFrame(Sender: TObject);
var
  i, N, k: Integer;
  F: TFrameRecord;
  PartH: Int64;
  NewFrames: TFrameList;
  Inserted, SelectedCount: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  N := FSpinSplitN.Value;
  if N < 2 then Exit;

  SelectedCount := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
      Inc(SelectedCount);
  if SelectedCount = 0 then
  begin
    ShowMessage('No frames selected to split.');
    Exit;
  end;
  if (SelectedCount > 1) and
     ((not Assigned(FChkSplitConfirmMulti)) or FChkSplitConfirmMulti.Checked) then
    if MessageDlg(Format('Split %d selected frames into %d parts each?',
       [SelectedCount, N]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;

  NewFrames := nil;
  Inserted  := 0;
  { Build a new frame list, replacing each selected frame with N equal parts }
  SetLength(NewFrames, 0);
  for i := 0 to High(FFrames) do
  begin
    F := FFrames[i];
    if F.IsSelected then
    begin
      PartH := (F.TrailEdge - F.LeadEdge) div N;
      if PartH < 1 then PartH := 1;
      for k := 0 to N - 1 do
      begin
        SetLength(NewFrames, Length(NewFrames) + 1);
        NewFrames[High(NewFrames)]            := F;
        NewFrames[High(NewFrames)].LeadEdge   := F.LeadEdge + k * PartH;
        if k = N - 1 then
          NewFrames[High(NewFrames)].TrailEdge := F.TrailEdge
        else
          NewFrames[High(NewFrames)].TrailEdge := F.LeadEdge + (k + 1) * PartH;
        NewFrames[High(NewFrames)].IsSelected  := True;
        Inc(Inserted);
      end;
    end
    else
    begin
      SetLength(NewFrames, Length(NewFrames) + 1);
      NewFrames[High(NewFrames)] := F;
    end;
  end;

  PushFrameUndo;

  { Re-index }
  for i := 0 to High(NewFrames) do NewFrames[i].Index := i;
  FFrames := NewFrames;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.DoAutoStrips;
var
  SW, NewCount: Integer;
begin
  if not FChkAutoStrips.Checked then Exit;
  SW := FStripView.StripDisplayW;
  if SW <= 0 then Exit;
  NewCount := Max(1, Min(20, FStripView.ClientWidth div SW));

  FAutoLayoutUpdating := True;
  try
    FSpinStrips.Value := NewCount;
    FStripView.StripsPerRow := NewCount;
  finally
    FAutoLayoutUpdating := False;
  end;
  UpdateNavButtons;
  UpdateStatus;
end;

procedure TMainForm.MarkDirty;
begin
  FDirty := True;
  if FCurrentProjectPath <> '' then
    SetAppTitle('*' + ExtractFileName(FCurrentProjectPath))
  else if FCurrentIDFPath <> '' then
    SetAppTitle('*' + ExtractFileName(FCurrentIDFPath))
  else
    SetAppTitle('*');
end;

procedure TMainForm.PushFrameUndo;
const
  MAX_UNDO_STEPS = 25;
var
  i: Integer;
begin
  if FRollData.Loaded then
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));

  if Length(FUndoFrames) >= MAX_UNDO_STEPS then
  begin
    for i := 1 to High(FUndoFrames) do
      FUndoFrames[i - 1] := FUndoFrames[i];
    SetLength(FUndoFrames, MAX_UNDO_STEPS - 1);
  end;

  SetLength(FUndoFrames, Length(FUndoFrames) + 1);
  FUndoFrames[High(FUndoFrames)] := Copy(FFrames, 0, Length(FFrames));
  FBtnDetectUndo.Enabled := Length(FUndoFrames) > 0;
end;

procedure TMainForm.ClearFrameUndo;
begin
  SetLength(FUndoFrames, 0);
  FBtnDetectUndo.Enabled := False;
end;

procedure TMainForm.UndoLastFrameChange;
var
  Last: Integer;
begin
  Last := High(FUndoFrames);
  if Last < 0 then Exit;

  FFrames := Copy(FUndoFrames[Last], 0, Length(FUndoFrames[Last]));
  SetLength(FUndoFrames, Last);
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  FBtnDetectUndo.Enabled := Length(FUndoFrames) > 0;
end;

procedure TMainForm.JumpToMarker(Forward: Boolean);
var
  StartIdx, i, TargetIdx: Integer;
  StripIdx, Row, Page: Integer;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) = 0 then Exit;

  StartIdx := GetSingleSelectedFrameIdx;
  if StartIdx < 0 then
  begin
    StartIdx := High(FFrames);
    if Forward then
      for i := 0 to High(FFrames) do
        if FrameLeadStrip(FFrames[i], FRollData.LengthLines) >= FStripView.FirstStrip then
        begin
          StartIdx := i - 1;
          Break;
        end;
  end;

  TargetIdx := -1;
  if Forward then
  begin
    for i := StartIdx + 1 to High(FFrames) do
      if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
    if TargetIdx < 0 then
      for i := 0 to StartIdx do
        if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
  end
  else
  begin
    for i := StartIdx - 1 downto 0 do
      if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
    if TargetIdx < 0 then
      for i := High(FFrames) downto StartIdx do
        if FFrames[i].IsMarker then begin TargetIdx := i; Break; end;
  end;

  if TargetIdx < 0 then Exit;

  StripIdx := FrameLeadStrip(FFrames[TargetIdx], FRollData.LengthLines);
  Row := StripIdx div Max(1, FStripView.StripsPerRow);
  Page := Row div Max(1, FStripView.RowsPerPage);
  FStripView.GotoPage(Page);
  FStripView.SelectFrame(TargetIdx);
  UpdateNavButtons;
  UpdateStatus;
end;

function TMainForm.PreviewCacheRoot: String;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
            'Striplight_preview_cache';
end;

function TMainForm.PreviewCacheProjectName: String;
var
  S: String;
  i: Integer;
begin
  if FCurrentIDFPath <> '' then
    S := ChangeFileExt(ExtractFileName(FCurrentIDFPath), '')
  else if FRollData.RollName <> '' then
    S := FRollData.RollName
  else
    S := 'current_project';

  for i := 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', ' ', '.']) then
      S[i] := '_';
  S := Trim(S);
  if S = '' then S := 'current_project';
  Result := S;
end;

function TMainForm.PreviewCacheProjectRoot: String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewCacheRoot) + PreviewCacheProjectName;
end;

function TMainForm.PreviewCacheProjectNameForIDF(const IDFPath: String): String;
var
  S: String;
  i: Integer;
begin
  S := ChangeFileExt(ExtractFileName(IDFPath), '');
  for i := 1 to Length(S) do
    if not (S[i] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', ' ', '.']) then
      S[i] := '_';
  S := Trim(S);
  if S = '' then S := 'project';
  Result := S;
end;

function TMainForm.PreviewCacheProjectRootForIDF(const IDFPath: String): String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewCacheRoot) + PreviewCacheProjectNameForIDF(IDFPath);
end;

function TMainForm.CacheQueueFile: String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewCacheRoot) + 'cache_queue.txt';
end;

procedure TMainForm.LoadCacheQueue;
begin
  if Assigned(FCacheQueuePaths) and FileExists(CacheQueueFile) then
    FCacheQueuePaths.LoadFromFile(CacheQueueFile);
end;

procedure TMainForm.SaveCacheQueue;
begin
  if not Assigned(FCacheQueuePaths) then Exit;
  ForceDirectories(PreviewCacheRoot);
  FCacheQueuePaths.SaveToFile(CacheQueueFile);
end;

function TMainForm.CacheQueueStatusForProject(const ProjectPath: String;
  DeepCheck: Boolean): String;
var
  Roll: TRollData;
  Frames: TFrameList;
  ParseResult: TIDFParseResult;
  CacheBase, CacheDir, PreviewPath: String;
  i, Existing: Integer;
begin
  CacheBase := IncludeTrailingPathDelimiter(PreviewCacheProjectRootForIDF(ProjectPath));
  CacheDir := CacheBase + 'previews';
  if not DirectoryExists(CacheDir) then
    Exit('[not cached] ');
  if not DeepCheck then
    Exit('[cache found] ');

  Frames := nil;
  ParseResult := ParseIDF(ProjectPath, Roll, Frames);
  if (ParseResult <> iprOK) or (Roll.StripCount <= 0) then
    Exit('[partial] ');

  Roll.PreviewBasePath := CacheBase;
  Roll.PreviewFolder := 'previews';
  Roll.PreviewCacheEnabled := True;

  Existing := 0;
  for i := 0 to Roll.StripCount - 1 do
  begin
    PreviewPath := IncludeTrailingPathDelimiter(Roll.PreviewBasePath)
                 + Roll.PreviewFolder
                 + PathDelim
                 + Roll.PreviewPrefix
                 + ZeroPadInt(i + 1, Roll.StripDigits)
                 + '.jpg';
    if FileExists(PreviewPath) then
      Inc(Existing);
  end;

  if Existing >= Roll.StripCount then
    Result := '[cached] '
  else if Existing > 0 then
    Result := '[partial] '
  else
    Result := '[not cached] ';
end;

procedure TMainForm.RefreshCacheQueueList(DeepCheck: Boolean);
var
  i: Integer;
  S, Status: String;
begin
  if not Assigned(FCacheList) then Exit;
  FCacheList.Items.BeginUpdate;
  try
    FCacheList.Items.Clear;
    for i := 0 to FCacheQueuePaths.Count - 1 do
    begin
      if FCacheQueueRunning and (i = FCacheQueueIndex) then
        Status := '[working] '
      else
        Status := CacheQueueStatusForProject(FCacheQueuePaths[i], DeepCheck);
      S := Status + FCacheQueuePaths[i];
      FCacheList.Items.Add(S);
    end;
    if FCacheQueueRunning and (FCacheQueueIndex >= 0) and
       (FCacheQueueIndex < FCacheList.Items.Count) then
      FCacheList.ItemIndex := FCacheQueueIndex;
  finally
    FCacheList.Items.EndUpdate;
  end;
  if Assigned(FCacheMgrStatus) and not Assigned(FCacheScanThread) and not FCacheQueueRunning then
  begin
    if DeepCheck then
      FCacheMgrStatus.Caption := Format('Projects in queue: %d   Cache status verified.', [FCacheQueuePaths.Count])
    else
      FCacheMgrStatus.Caption := Format('Projects in queue: %d   Refresh List verifies complete/partial cache status.',
        [FCacheQueuePaths.Count]);
  end;
end;

procedure TMainForm.AddCacheQueuePath(const Path: String);
var
  P, Ext: String;
begin
  P := Trim(Path);
  if (Length(P) >= 2) and (P[1] = '"') and (P[Length(P)] = '"') then
    P := Copy(P, 2, Length(P) - 2);
  if P = '' then Exit;

  if DirectoryExists(P) then
  begin
    AddCacheQueueFolder(P);
    Exit;
  end;

  Ext := LowerCase(ExtractFileExt(P));
  if ((Ext = '.idf') or (Ext = '.xml')) and FileExists(P) then
    if FCacheQueuePaths.IndexOf(P) < 0 then
      FCacheQueuePaths.Add(P);
end;

procedure TMainForm.AddCacheQueueFolder(const Folder: String);
var
  SR: TSearchRec;
  Path, Ext: String;
begin
  if not DirectoryExists(Folder) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*', faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Path := IncludeTrailingPathDelimiter(Folder) + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          AddCacheQueueFolder(Path)
        else
        begin
          Ext := LowerCase(ExtractFileExt(Path));
          if ((Ext = '.idf') or (Ext = '.xml')) and (FCacheQueuePaths.IndexOf(Path) < 0) then
            FCacheQueuePaths.Add(Path);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TMainForm.StartNextCacheQueueItem;
var
  ParseResult: TIDFParseResult;
  Roll: TRollData;
  Frames: TFrameList;
begin
  if FCacheQueueStopRequested or (FCacheQueueIndex >= FCacheQueuePaths.Count) then
  begin
    FCacheQueueRunning := False;
    FBgCacheQueueMode := False;
    if Assigned(FBtnCacheMgrStart) then FBtnCacheMgrStart.Enabled := True;
    if Assigned(FBtnCacheMgrStop) then FBtnCacheMgrStop.Enabled := False;
    if Assigned(FCacheMgrStatus) then
      FCacheMgrStatus.Caption := 'Queue stopped or complete.';
    Exit;
  end;

  Frames := nil;
  ParseResult := ParseIDF(FCacheQueuePaths[FCacheQueueIndex], Roll, Frames);
  if ParseResult <> iprOK then
  begin
    Inc(FCacheQueueIndex);
    StartNextCacheQueueItem;
    Exit;
  end;

  Roll.PreviewBasePath := IncludeTrailingPathDelimiter(PreviewCacheProjectRootForIDF(FCacheQueuePaths[FCacheQueueIndex]));
  Roll.PreviewFolder := 'previews';
  Roll.PreviewCacheEnabled := True;
  ForceDirectories(IncludeTrailingPathDelimiter(Roll.PreviewBasePath) + Roll.PreviewFolder);

  RefreshCacheQueueList;
  if Assigned(FCacheMgrStatus) then
    FCacheMgrStatus.Caption := Format('Caching project %d / %d: %s',
      [FCacheQueueIndex + 1, FCacheQueuePaths.Count, ExtractFileName(FCacheQueuePaths[FCacheQueueIndex])]);
  FBgCacheThread := TPreviewCacheThread.Create(Self, Roll);
end;

procedure TMainForm.PurgeAllPreviewCaches;
var
  Root: String;

  procedure DeleteTree(const Dir: String);
  var
    SR: TSearchRec;
    Path: String;
  begin
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          Path := IncludeTrailingPathDelimiter(Dir) + SR.Name;
          if (SR.Attr and faDirectory) <> 0 then
            DeleteTree(Path)
          else
            SysUtils.DeleteFile(Path);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    RemoveDir(Dir);
  end;

begin
  Root := ExcludeTrailingPathDelimiter(PreviewCacheRoot);
  if ExtractFileName(Root) <> 'Striplight_preview_cache' then Exit;
  if DirectoryExists(Root) then
    DeleteTree(Root);
end;

procedure TMainForm.PreparePreviewCacheForRoll;
var
  CacheRoot, DestDir: String;
begin
  CacheRoot := IncludeTrailingPathDelimiter(PreviewCacheProjectRoot);
  DestDir := CacheRoot + 'previews';
  try
    ForceDirectories(DestDir);
    FRollData.PreviewSourceBasePath := FRollData.BasePath;
    FRollData.PreviewSourceFolder := FRollData.PreviewFolder;
    FRollData.PreviewBasePath := CacheRoot;
    FRollData.PreviewFolder := 'previews';
    FRollData.PreviewCacheEnabled := True;
    FLblDetectStatus.Caption := 'Preview cache is on; missing previews will cache during detection.';
  except
    FRollData.PreviewCacheEnabled := False;
    FRollData.PreviewBasePath := FRollData.BasePath;
    FRollData.PreviewFolder := FRollData.PreviewSourceFolder;
    FLblDetectStatus.Caption := 'Preview cache unavailable; using original preview folder.';
  end;
end;

procedure TMainForm.BackgroundCacheProgress(Copied, Skipped, Missing, Current, Total: Integer;
  const Status: String);
begin
  FLblDetectStatus.Caption := Status;
  FStatusBar.Panels[4].Text := Status;
  if Assigned(FCacheMgrStatus) then
    FCacheMgrStatus.Caption := Status;
end;

procedure TMainForm.BackgroundCacheDone(Copied, Skipped, Missing, Total: Integer;
  Cancelled: Boolean);
begin
  FBgCacheThread := nil;

  if FBgCacheQueueMode then
  begin
    if Assigned(FCacheMgrStatus) then
    begin
      if Cancelled then
        FCacheMgrStatus.Caption := Format('Stopped project %d / %d. Copied: %d   Already cached: %d   Missing: %d',
          [FCacheQueueIndex + 1, FCacheQueuePaths.Count, Copied, Skipped, Missing])
      else
        FCacheMgrStatus.Caption := Format('Finished project %d / %d. Copied: %d   Already cached: %d   Missing: %d',
          [FCacheQueueIndex + 1, FCacheQueuePaths.Count, Copied, Skipped, Missing]);
    end;
    Inc(FCacheQueueIndex);
    RefreshCacheQueueList;
    if Cancelled or FCacheQueueStopRequested then
    begin
      FCacheQueueRunning := False;
      FBgCacheQueueMode := False;
      if Assigned(FBtnCacheMgrStart) then FBtnCacheMgrStart.Enabled := True;
      if Assigned(FBtnCacheMgrStop) then FBtnCacheMgrStop.Enabled := False;
      Exit;
    end;
    StartNextCacheQueueItem;
    Exit;
  end;

  if Assigned(FBtnBgCache) then
    SetSpeedButtonAction(FBtnBgCache, 'Start Cache');
  if Cancelled then
    FLblDetectStatus.Caption := Format('Background cache stopped. Copied: %d   Already cached: %d   Missing: %d',
      [Copied, Skipped, Missing])
  else
    FLblDetectStatus.Caption := Format('Background cache complete. Copied: %d   Already cached: %d   Missing: %d',
      [Copied, Skipped, Missing]);
  FStatusBar.Panels[4].Text := FLblDetectStatus.Caption;
end;

procedure TMainForm.CacheScanProgress(ScannedFolders, ScannedFiles, FoundCount: Integer;
  const Current: String);
begin
  if Assigned(FCacheMgrStatus) then
    FCacheMgrStatus.Caption := Format('Scanning... Folders: %d   Files: %d   Projects found: %d   %s',
      [ScannedFolders, ScannedFiles, FoundCount, Current]);
end;

procedure TMainForm.CacheScanDone(Found: TStrings; ScannedFolders, ScannedFiles: Integer;
  Cancelled: Boolean);
var
  i, Added: Integer;
begin
  Added := 0;
  for i := 0 to Found.Count - 1 do
    if FCacheQueuePaths.IndexOf(Found[i]) < 0 then
    begin
      FCacheQueuePaths.Add(Found[i]);
      Inc(Added);
    end;
  SaveCacheQueue;
  RefreshCacheQueueList;
  if Assigned(FCacheMgrStatus) then
  begin
    if Cancelled then
      FCacheMgrStatus.Caption := Format('Scan stopped. Added: %d   Folders: %d   Files: %d',
        [Added, ScannedFolders, ScannedFiles])
    else
      FCacheMgrStatus.Caption := Format('Scan complete. Added: %d   Found: %d   Folders: %d   Files: %d',
        [Added, Found.Count, ScannedFolders, ScannedFiles]);
  end;
  if Assigned(FBtnCacheMgrAddPaths) then FBtnCacheMgrAddPaths.Enabled := True;
  if Assigned(FBtnCacheMgrAddFolder) then FBtnCacheMgrAddFolder.Enabled := True;
  FCacheScanThread := nil;
end;

procedure TMainForm.StopCacheScan(WaitForFinish: Boolean);
begin
  if not Assigned(FCacheScanThread) then Exit;
  FCacheScanThread.Terminate;
  if Assigned(FBtnCacheMgrAddPaths) then FBtnCacheMgrAddPaths.Enabled := True;
  if Assigned(FBtnCacheMgrAddFolder) then FBtnCacheMgrAddFolder.Enabled := True;
  if WaitForFinish then
  begin
    FCacheScanThread.FOwner := nil;
    FCacheScanThread.WaitFor;
    FreeAndNil(FCacheScanThread);
  end;
end;

procedure TMainForm.StopBackgroundCache(WaitForFinish: Boolean);
begin
  if not Assigned(FBgCacheThread) then Exit;
  FBgCacheThread.Terminate;
  if Assigned(FBtnBgCache) then
    SetSpeedButtonAction(FBtnBgCache, 'Start Cache');
  if WaitForFinish then
  begin
    FBgCacheThread.FOwner := nil;
    FBgCacheThread.WaitFor;
    FreeAndNil(FBgCacheThread);
  end;
end;

function TMainForm.SaveSLFToFile(const FileName: String;
  UpdateCurrentProject: Boolean): Boolean;
begin
  StoreAdjustmentControlsToRoll;
  StoreExportNamingControlsToRoll;
  Result := SaveSLF(FileName, FCurrentIDFPath, FRollData, FFrames);
  if Result then
  begin
    if UpdateCurrentProject then
      FCurrentProjectPath := FileName;
    FDirty := False;
    SetAppTitle(ExtractFileName(FileName));
    if Assigned(FLblDetectStatus) then
      FLblDetectStatus.Caption := 'Saved Striplight project. IDF was not changed.';
  end
  else
    ShowMessage('Could not write ' + FileName);
end;

function TMainForm.SaveQPFToFile(const FileName: String): Boolean;
begin
  Result := SaveQPF(FileName, FCurrentIDFPath, FRollData, FFrames);
  if Result then
  begin
    if Assigned(FLblDetectStatus) then
      FLblDetectStatus.Caption := 'Saved QPF compatibility file. IDF was not changed.';
  end
  else
    ShowMessage('Could not write ' + FileName);
end;

function TMainForm.PromptSaveSLFAs: Boolean;
var
  Dlg: TSaveDialog;
  DefaultName: String;
begin
  Result := False;
  if not FRollData.Loaded then Exit;
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Title := 'Save Striplight Project';
    Dlg.Filter := 'Striplight Files (*.slf)|*.slf|All Files (*.*)|*.*';
    Dlg.DefaultExt := 'slf';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt, ofPathMustExist];
    if FCurrentProjectPath <> '' then
      Dlg.FileName := FCurrentProjectPath
    else
    begin
      DefaultName := FRollData.RollName;
      if DefaultName = '' then
        DefaultName := ChangeFileExt(ExtractFileName(FCurrentIDFPath), '');
      Dlg.FileName := ChangeFileExt(DefaultName, '.slf');
      if FCurrentIDFPath <> '' then
        Dlg.InitialDir := ExtractFilePath(FCurrentIDFPath);
    end;
    if Dlg.Execute then
      Result := SaveSLFToFile(ChangeFileExt(Dlg.FileName, '.slf'), True);
  finally
    Dlg.Free;
  end;
end;

function TMainForm.PromptSaveQPFAs: Boolean;
var
  Dlg: TSaveDialog;
  DefaultName: String;
begin
  Result := False;
  if not FRollData.Loaded then Exit;
  Dlg := TSaveDialog.Create(Self);
  try
    Dlg.Title := 'Save QPF Compatibility File';
    Dlg.Filter := 'QPF Files (*.qpf)|*.qpf|All Files (*.*)|*.*';
    Dlg.DefaultExt := 'qpf';
    Dlg.Options := Dlg.Options + [ofOverwritePrompt, ofPathMustExist];
    DefaultName := FRollData.RollName;
    if DefaultName = '' then
      DefaultName := ChangeFileExt(ExtractFileName(FCurrentIDFPath), '');
    Dlg.FileName := ChangeFileExt(DefaultName, '.qpf');
    if FCurrentIDFPath <> '' then
      Dlg.InitialDir := ExtractFilePath(FCurrentIDFPath);
    if Dlg.Execute then
      Result := SaveQPFToFile(ChangeFileExt(Dlg.FileName, '.qpf'));
  finally
    Dlg.Free;
  end;
end;

procedure TMainForm.LoadProjectFile(const ProjectPath: String);
var
  Ext: String;
  LoadedArchiveList: String;
  ProjectFrames: TFrameList;
  ProjectRoll: TRollData;
begin
  Ext := LowerCase(ExtractFileExt(ProjectPath));
  StopBackgroundCache(False);

  ProjectFrames := nil;
  LoadedArchiveList := '';
  if (Ext = '.slf') and LoadSLFProject(ProjectPath, ProjectRoll, ProjectFrames) then
  begin
    LoadedArchiveList := ProjectRoll.StriplightArchiveList;
    FRollData := ProjectRoll;
    FFrames := ProjectFrames;
    FCurrentProjectPath := ProjectPath;
    FCurrentIDFPath := SLFSourceIDFPath(ProjectPath);
  end
  else if (Ext = '.qpf') and LoadQPFProject(ProjectPath, ProjectRoll, ProjectFrames) then
  begin
    FRollData := ProjectRoll;
    FFrames := ProjectFrames;
    FCurrentProjectPath := '';
    FCurrentIDFPath := '';
  end
  else
  begin
    ShowMessage('Could not read ' + ProjectPath);
    Exit;
  end;

  if Assigned(FChkCachePreviews) and FChkCachePreviews.Checked then
    PreparePreviewCacheForRoll;

  SetAppTitle(ExtractFileName(ProjectPath));
  CalculateFrameStats(FFrames, FFrameStats);
  FStripView.LoadRoll(FRollData, FFrames);
  RefreshFrameColors;
  UpdateFilesTab;
  FEdtRangeFrom.MaxValue := Max(1, FRollData.StripCount);
  FEdtRangeTo.MaxValue   := Max(1, FRollData.StripCount);
  FEdtRangeFrom.Value    := 1;
  FEdtRangeTo.Value      := Max(1, FRollData.StripCount);
  FSpinMinW.Value        := Max(FSpinMinW.MinValue, Min(FSpinMinW.MaxValue, FRollData.DetectMinWidth));
  FSpinMinH.Value        := Max(FSpinMinH.MinValue, Min(FSpinMinH.MaxValue, FRollData.DetectMinLength));
  if Ext = '.slf' then
    LoadAdjustmentControlsFromRoll
  else
    OnScanDefaults(Self);
  if Ext = '.slf' then
  begin
    { Restore the parser result directly after every control-loading callback.
      This prevents any UI OnChange side effect from clearing the memo. }
    FRollData.StriplightArchiveList := LoadedArchiveList;
    FUpdatingExportNaming := True;
    try
      if Assigned(FMemoArchiveList) then
        FMemoArchiveList.Lines.Text := LoadedArchiveList;
    finally
      FUpdatingExportNaming := False;
    end;
  end;
  SyncDetectRangeToView;
  ClearFrameUndo;
  FDirty := False;
  UpdateNavButtons;
  UpdateStatus;
  ShowMessage(Format('Loaded "%s"'#13#10'Strips: %d  |  Frames: %d'#13#10 +
    'Archive list: %d characters loaded',
    [ExtractFileName(ProjectPath), FRollData.StripCount, Length(FFrames),
     Length(LoadedArchiveList)]));
end;

function TMainForm.ResolvePreviewPathForDetection(StripIndex: Integer;
  out Path: String; out CachedNow: Boolean): Boolean;
var
  CachePath: String;
  HadCache: Boolean;
begin
  Result := False;
  CachedNow := False;
  Path := '';

  CachePath := IncludeTrailingPathDelimiter(FRollData.PreviewBasePath)
             + FRollData.PreviewFolder
             + PathDelim
             + FRollData.PreviewPrefix
             + ZeroPadInt(StripIndex + 1, FRollData.StripDigits)
             + '.jpg';
  HadCache := FRollData.PreviewCacheEnabled and FileExists(CachePath);
  Path := PreviewFilePath(FRollData, StripIndex);
  Result := FileExists(Path);
  CachedNow := FRollData.PreviewCacheEnabled and (not HadCache) and SameText(Path, CachePath);
end;

procedure TMainForm.ApplyZoomPercent(Value: Integer);
begin
  Value := Max(FTrackZoom.Min, Min(FTrackZoom.Max, Value));
  FApplyingZoom := True;
  try
    FTrackZoom.Position := Value;
    FSpinZoom.Value := Value;
  finally
    FApplyingZoom := False;
  end;
  FStripView.Zoom := Value / 100.0;
  UpdateNavButtons;
  UpdateStatus;
end;

procedure TMainForm.SyncDetectRangeToView;
var
  StartStrip, EndStrip: Integer;
begin
  if FUpdatingDetectRange then Exit;
  if not Assigned(FStripView) then Exit;
  FUpdatingDetectRange := True;
  try
    StartStrip := Max(1, FEdtRangeFrom.Value) - 1;
    EndStrip   := Max(1, FEdtRangeTo.Value) - 1;
    if FRollData.Loaded then
    begin
      StartStrip := Max(0, Min(StartStrip, FRollData.StripCount - 1));
      EndStrip   := Max(0, Min(EndStrip,   FRollData.StripCount - 1));
    end;
    if EndStrip < StartStrip then EndStrip := StartStrip;
    FStripView.DetectStartStrip := StartStrip;
    FStripView.DetectEndStrip   := EndStrip;
    FStripView.DetectRangeEnabled := FRbDetectRange.Checked;
  finally
    FUpdatingDetectRange := False;
  end;
end;

procedure TMainForm.ReplaceFramesInStripRange(const DetectedFrames: TFrameList;
                                              FromStrip, ToStrip: Integer);
var
  NewList: TFrameList;
  i, OutIdx: Integer;
  RangeLead, RangeTrail: Int64;

  procedure AppendFrame(const F: TFrameRecord);
  begin
    SetLength(NewList, Length(NewList) + 1);
    NewList[High(NewList)] := F;
  end;

begin
  SetLength(NewList, 0);
  RangeLead  := Int64(FromStrip) * FRollData.LengthLines;
  RangeTrail := Int64(ToStrip + 1) * FRollData.LengthLines;

  for i := 0 to High(FFrames) do
    if FFrames[i].TrailEdge <= RangeLead then
      AppendFrame(FFrames[i]);

  for i := 0 to High(DetectedFrames) do
    AppendFrame(DetectedFrames[i]);

  for i := 0 to High(FFrames) do
    if FFrames[i].LeadEdge >= RangeTrail then
      AppendFrame(FFrames[i]);

  for OutIdx := 0 to High(NewList) do
    NewList[OutIdx].Index := OutIdx;

  FFrames := NewList;
end;

function TMainForm.OnDetectProgress(CurrentStrip, TotalStrips: Integer;
                                    const Stats: TDetectStats;
                                    const Frames: TFrameList): Boolean;
var
  AbsStrip, Row, Page: Integer;
begin
  if TotalStrips <= 0 then TotalStrips := 1;
  FProgressDetect.Max := TotalStrips;
  FProgressDetect.Position := Min(CurrentStrip, TotalStrips);
  if Stats.CacheCopied > 0 then
    FLblDetectStatus.Caption := Format('Detecting strip %d / %d   Frames: %d   Missing: %d   Cached: %d',
      [CurrentStrip, TotalStrips, Stats.FramesFound, Stats.StripsMissing, Stats.CacheCopied])
  else
    FLblDetectStatus.Caption := Format('Detecting strip %d / %d   Frames: %d   Missing: %d',
      [CurrentStrip, TotalStrips, Stats.FramesFound, Stats.StripsMissing]);
  FStatusBar.Panels[4].Text := FLblDetectStatus.Caption;

  if Assigned(FChkDetectLivePreview) and FChkDetectLivePreview.Checked then
  begin
    FFrames := Copy(FDetectBaseFrames, 0, Length(FDetectBaseFrames));
    if FRbDetectRange.Checked then
      ReplaceFramesInStripRange(Frames, FDetectLiveFromStrip, FDetectLiveFromStrip + TotalStrips - 1)
    else
      FFrames := Copy(Frames, 0, Length(Frames));

    CalculateFrameStats(FFrames, FFrameStats);
    RefreshFrameColors;

    AbsStrip := FDetectLiveFromStrip + CurrentStrip - 1;
    Row := AbsStrip div Max(1, FStripView.StripsPerRow);
    Page := Row div Max(1, FStripView.RowsPerPage);
    FStripView.GotoPage(Page);
    UpdateNavButtons;
    UpdateStatus;
  end;

  Application.ProcessMessages;
  Result := not FDetectCancel;
end;

procedure TMainForm.ReloadFramesKeepPage;
var
  Page: Integer;
begin
  Page := FStripView.CurrentPage;
  FStripView.UpdateFrames(FFrames);
  if FStripView.TotalPages > 0 then
    FStripView.GotoPage(Min(Page, FStripView.TotalPages - 1));
end;

procedure TMainForm.OnAutoStripsToggle(Sender: TObject);
begin
  DoAutoStrips;
end;

procedure TMainForm.OnMultiManipToggle(Sender: TObject);
begin
  FStripView.MultiManipulate := FChkMultiManip.Checked;
end;

procedure TMainForm.OnLeftPanelResize(Sender: TObject);
begin
  DoAutoStrips;
end;

procedure TMainForm.OnSaveQPF(Sender: TObject);
begin
  OnSave(Sender);
end;

procedure TMainForm.OnExitApp(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.OnViewStripEdges(Sender: TObject);
begin
  { FMenuMIStripEdges.Checked is toggled automatically by AutoCheck }
  FStripView.ShowStripEdges := FMenuMIStripEdges.Checked;
end;

procedure TMainForm.OnGoTo(Sender: TObject);
var
  S: String;
  N, StripIdx, Row, Page: Integer;
begin
  if not FRollData.Loaded then Exit;

  S := InputBox('Go To', 'Enter frame number (1–' + IntToStr(Length(FFrames)) + ')'
                        + #13#10 + 'or leave blank to go to a page:',
                '');

  if Trim(S) <> '' then
  begin
    { Go to frame }
    N := StrToIntDef(S, 0);
    if (N < 1) or (N > Length(FFrames)) then
    begin
      ShowMessage('Frame number out of range.');
      Exit;
    end;
    StripIdx := FrameLeadStrip(FFrames[N - 1], FRollData.LengthLines);
    Row  := StripIdx div FStripView.StripsPerRow;
    Page := Row div FStripView.RowsPerPage;
    FStripView.GotoPage(Page);
    FStripView.SelectFrame(N - 1);
    UpdateNavButtons;
    UpdateStatus;
  end
  else
  begin
    { Go to page }
    S := InputBox('Go To Page',
                  'Enter page number (1–' + IntToStr(FStripView.TotalPages) + '):',
                  '');
    N := StrToIntDef(S, 0);
    if (N >= 1) and (N <= FStripView.TotalPages) then
    begin
      FStripView.GotoPage(N - 1);
      UpdateNavButtons;
      UpdateStatus;
    end
    else if Trim(S) <> '' then
      ShowMessage('Page number out of range.');
  end;
end;

procedure TMainForm.OnSettings(Sender: TObject);
begin
  ShowMessage('Settings dialog will be implemented in a later phase.'#13#10
            + '(Configurable: frame colours, keyboard shortcuts, default paths)');
end;

procedure TMainForm.OnAbout(Sender: TObject);
begin
  ShowMessage('Striplight'#13#10
            + 'Version 0.1 (Phase 1 – Display Engine)'#13#10#13#10
            + 'Microfilm processing application'#13#10
            + 'Built with Free Pascal + Lazarus LCL + BGRABitmap'#13#10#13#10
            + 'Author: Tom');
end;

procedure TMainForm.OnDetectStart(Sender: TObject);
var
  Options: TDetectOptions;
  NewFrames: TFrameList;
  Stats: TDetectStats;
  FromStrip, ToStrip: Integer;
  Completed: Boolean;
begin
  if not FRollData.Loaded then Exit;
  if FDetectRunning then Exit;
  if Assigned(FChkCachePreviews) and FChkCachePreviews.Checked and
     not FRollData.PreviewCacheEnabled then
    PreparePreviewCacheForRoll;

  FromStrip := 0;
  ToStrip := FRollData.StripCount - 1;
  if FRbDetectRange.Checked then
  begin
    FromStrip := Max(1, FEdtRangeFrom.Value) - 1;
    ToStrip   := Max(1, FEdtRangeTo.Value) - 1;
    if ToStrip < FromStrip then
    begin
      ShowMessage('Detection range is invalid.');
      Exit;
    end;
  end;

  if Length(FFrames) > 0 then
  begin
    if FRbDetectRange.Checked then
    begin
      if MessageDlg(Format('Replace frames only inside strips %d to %d with newly detected frames?'#13#10 +
                           'Frames outside this range will be kept.',
                           [FromStrip + 1, ToStrip + 1]),
                    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
    end
    else if MessageDlg('Replace the full current frame list with newly detected frames?',
                       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  end;

  Options.StripFrom       := FromStrip;
  Options.StripTo         := ToStrip;
  Options.MinWidthPx      := FSpinMinW.Value;
  Options.MinHeightPx     := FSpinMinH.Value;
  Options.Brightness      := FTrackBrightness.Position;
  Options.Contrast        := FTrackContrast.Position;
  Options.Gamma           := FTrackGamma.Position;
  Options.Threshold       := FRollData.DetectionThreshold;
  Options.MergeAcrossGaps := FRollData.LengthLines div 64;
  Options.DetectLeftInsetPx := 0;
  Options.DetectRightInsetPx := 0;
  if Assigned(FChkDetectAreaEnable) and FChkDetectAreaEnable.Checked and
     Assigned(FSpinDetectIgnoreTop) then
    Options.DetectLeftInsetPx := FSpinDetectIgnoreTop.Value;
  if Assigned(FChkDetectAreaEnable) and FChkDetectAreaEnable.Checked and
     Assigned(FSpinDetectIgnoreBottom) then
    Options.DetectRightInsetPx := FSpinDetectIgnoreBottom.Value;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  FDetectBaseFrames := Copy(FFrames, 0, Length(FFrames));
  FDetectLiveFromStrip := FromStrip;
  PushFrameUndo;

  FDetectCancel := False;
  FDetectRunning := True;
  FBtnDetectStart.Enabled := False;
  FBtnDetectStop.Enabled := True;
  FBtnDetectUndo.Enabled := Length(FUndoFrames) > 0;
  FProgressDetect.Position := 0;
  FLblDetectStatus.Caption := 'Starting detection...';
  Application.ProcessMessages;

  try
    Completed := DetectFramesFromPreviews(FRollData, Options, NewFrames, Stats,
      @OnDetectProgress, @ResolvePreviewPathForDetection);
  finally
    FDetectRunning := False;
    FBtnDetectStart.Enabled := True;
    FBtnDetectStop.Enabled := False;
  end;

  if not Completed and (Stats.StripsRead = 0) then
  begin
    FLblDetectStatus.Caption := 'Detection stopped before any previews were read.';
    ShowMessage('Detection could not read any preview strips.');
    Exit;
  end;

  if FRbDetectRange.Checked then
    ReplaceFramesInStripRange(NewFrames, FromStrip, ToStrip)
  else
    FFrames := NewFrames;
  CalculateFrameStats(FFrames, FFrameStats);
  RefreshFrameColors;
  ReloadFramesKeepPage;
  MarkDirty;
  UpdateStatus;
  FBtnDetectUndo.Enabled := Length(FUndoFrames) > 0;
  if not FDetectCancel then
    FProgressDetect.Position := FProgressDetect.Max;

  if FDetectCancel then
    FLblDetectStatus.Caption := Format('Detection stopped. Frames: %d   Previews read: %d   Missing: %d   Cached: %d',
      [Stats.FramesFound, Stats.StripsRead, Stats.StripsMissing, Stats.CacheCopied])
  else
    FLblDetectStatus.Caption := Format('Detection complete. Frames: %d   Previews read: %d   Missing: %d   Cached: %d',
      [Stats.FramesFound, Stats.StripsRead, Stats.StripsMissing, Stats.CacheCopied]);

  if FDetectCancel then
    ShowMessage(Format('Detection stopped.'#13#10 +
                     'Preview strips read: %d'#13#10 +
                     'Missing previews: %d'#13#10 +
                     'Previews cached locally: %d'#13#10 +
                     'Frames found so far: %d',
                     [Stats.StripsRead, Stats.StripsMissing, Stats.CacheCopied, Stats.FramesFound]))
  else
    ShowMessage(Format('Detection complete.'#13#10 +
                     'Preview strips read: %d'#13#10 +
                     'Missing previews: %d'#13#10 +
                     'Previews cached locally: %d'#13#10 +
                     'Frames found: %d',
                     [Stats.StripsRead, Stats.StripsMissing, Stats.CacheCopied, Stats.FramesFound]));
end;

procedure TMainForm.OnDetectStop(Sender: TObject);
begin
  FDetectCancel := True;
  FLblDetectStatus.Caption := 'Stopping after current strip...';
  FBtnDetectStop.Enabled := False;
  Application.ProcessMessages;
end;

procedure TMainForm.OnDetectRangeControlChanged(Sender: TObject);
begin
  SyncDetectRangeToView;
end;

procedure TMainForm.OnDetectAreaChanged(Sender: TObject);
begin
  if not Assigned(FStripView) then Exit;
  if Sender = FStripView then
  begin
    if Assigned(FSpinDetectIgnoreTop) then
    begin
      FSpinDetectIgnoreTop.OnChange := nil;
      FSpinDetectIgnoreTop.Value := FStripView.DetectAreaTopPx;
      FSpinDetectIgnoreTop.OnChange := @OnDetectAreaChanged;
    end;
    if Assigned(FSpinDetectIgnoreBottom) then
    begin
      FSpinDetectIgnoreBottom.OnChange := nil;
      FSpinDetectIgnoreBottom.Value := FStripView.DetectAreaBottomPx;
      FSpinDetectIgnoreBottom.OnChange := @OnDetectAreaChanged;
    end;
    Exit;
  end;

  if Assigned(FChkDetectAreaEnable) then
    FStripView.DetectAreaEnabled := FChkDetectAreaEnable.Checked;
  if Assigned(FSpinDetectIgnoreTop) then
    FStripView.DetectAreaTopPx := FSpinDetectIgnoreTop.Value;
  if Assigned(FSpinDetectIgnoreBottom) then
    FStripView.DetectAreaBottomPx := FSpinDetectIgnoreBottom.Value;
end;

procedure TMainForm.OnDetectAreaReset(Sender: TObject);
begin
  if Assigned(FSpinDetectIgnoreTop) then
    FSpinDetectIgnoreTop.Value := 0;
  if Assigned(FSpinDetectIgnoreBottom) then
    FSpinDetectIgnoreBottom.Value := 0;
  OnDetectAreaChanged(Sender);
end;

procedure TMainForm.OnDetectRangeViewChanged(Sender: TObject);
begin
  if FUpdatingDetectRange then Exit;
  FUpdatingDetectRange := True;
  try
    FEdtRangeFrom.Value := FStripView.DetectStartStrip + 1;
    FEdtRangeTo.Value   := FStripView.DetectEndStrip + 1;
    FRbDetectRange.Checked := True;
    FStripView.DetectRangeEnabled := True;
  finally
    FUpdatingDetectRange := False;
  end;
end;

procedure TMainForm.OnDetectUndo(Sender: TObject);
begin
  UndoLastFrameChange;
end;

procedure TMainForm.OnBrowseOutput(Sender: TObject);
var
  Dir: String;
begin
  Dir := FEdtOutputDir.Text;
  if SelectDirectory('Select Output Directory', '', Dir) then
  begin
    FEdtOutputDir.Text := Dir;
    UpdateStatus;
  end;
end;

procedure TMainForm.OnExportNamingChanged(Sender: TObject);
begin
  if FUpdatingExportNaming then Exit;
  StoreExportNamingControlsToRoll;
  UpdateStatus;
end;

procedure TMainForm.OnArchiveListChanged(Sender: TObject);
begin
  if FUpdatingExportNaming then Exit;
  StoreExportNamingControlsToRoll;
  MarkDirty;
  UpdateStatus;
end;

procedure TMainForm.OnBuildArchiveListFromFolders(Sender: TObject);
var
  RootDir, CleanRoot: String;
  Generated: TStringList;
  SkippedNames: Integer;

  procedure ScanLeafFolders(const CurrentDir, RelativeDir: String);
  var
    SR: TSearchRec;
    ChildNames: TStringList;
    ChildName, ChildRelative: String;
    I: Integer;
  begin
    ChildNames := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(CurrentDir) + '*', faDirectory, SR) = 0 then
      try
        repeat
          if ((SR.Attr and faDirectory) <> 0) and
             (SR.Name <> '.') and (SR.Name <> '..') then
          begin
            if Pos(';', SR.Name) > 0 then
              Inc(SkippedNames)
            else
              ChildNames.Add(SR.Name);
          end;
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;

      ChildNames.CustomSort(@NaturalStringListCompare);
      if (ChildNames.Count = 0) and (RelativeDir <> '') then
      begin
        ChildRelative := StringReplace(RelativeDir, PathDelim, ';', [rfReplaceAll]);
        Generated.Add(';' + ChildRelative);
        Exit;
      end;

      for I := 0 to ChildNames.Count - 1 do
      begin
        ChildName := ChildNames[I];
        if RelativeDir = '' then
          ChildRelative := ChildName
        else
          ChildRelative := IncludeTrailingPathDelimiter(RelativeDir) + ChildName;
        ScanLeafFolders(IncludeTrailingPathDelimiter(CurrentDir) + ChildName,
          ChildRelative);
      end;
    finally
      ChildNames.Free;
    end;
  end;

begin
  RootDir := '';
  if not SelectDirectory('Select archive folder structure', '', RootDir) then Exit;
  CleanRoot := ExcludeTrailingPathDelimiter(RootDir);

  Generated := TStringList.Create;
  try
    SkippedNames := 0;
    ScanLeafFolders(CleanRoot, '');
    if Generated.Count = 0 then
    begin
      ShowMessage('No subfolders were found under the selected folder.');
      Exit;
    end;

    if Assigned(FMemoArchiveList) and (Trim(FMemoArchiveList.Text) <> '') and
       (MessageDlg(Format('Replace the current archive list with %d row(s)?',
         [Generated.Count]), mtConfirmation, [mbYes, mbNo], 0) <> mrYes) then Exit;

    FMemoArchiveList.Lines.BeginUpdate;
    try
      FMemoArchiveList.Lines.Assign(Generated);
    finally
      FMemoArchiveList.Lines.EndUpdate;
    end;
    StoreExportNamingControlsToRoll;
    MarkDirty;
    UpdateStatus;
    if SkippedNames > 0 then
      ShowMessage(Format('Created %d archive-list row(s). Skipped %d folder name(s) containing ";".',
        [Generated.Count, SkippedNames]))
    else
      ShowMessage(Format('Created %d archive-list row(s) from the selected folder structure.',
        [Generated.Count]));
  finally
    Generated.Free;
  end;
end;

procedure TMainForm.ExportTrace(RunId: Integer; WorkerTag: PtrUInt; OrderIdx,
  FrameIdx: Integer; const Stage, Detail: String);
var
  Stream: TFileStream;
  Line: String;
begin
  if RunId <> FExportRunId then Exit;
  if FExportTracePath = '' then Exit;

  Line := Format('%s run=%d worker=%x order=%d frame=%d stage=%s detail=%s%s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), RunId, WorkerTag,
     OrderIdx, FrameIdx, Stage, Detail, LineEnding]);

  EnterCriticalsection(FExportLock);
  try
    FExportLastTrace := TrimRight(Line);
    try
      if FileExists(FExportTracePath) then
      begin
        Stream := TFileStream.Create(FExportTracePath, fmOpenWrite or fmShareDenyNone);
        Stream.Seek(0, soEnd);
      end
      else
        Stream := TFileStream.Create(FExportTracePath, fmCreate);
      try
        if Line <> '' then
          Stream.WriteBuffer(Pointer(Line)^, Length(Line));
      finally
        Stream.Free;
      end;
    except
      { Tracing must never interrupt export work. }
    end;
  finally
    LeaveCriticalsection(FExportLock);
  end;
end;

function TMainForm.WaitForExportCommitTurn(RunId, OrderIdx: Integer): Boolean;
var
  IsTurn: Boolean;
begin
  Result := False;
  while True do
  begin
    EnterCriticalsection(FExportLock);
    try
      if RunId <> FExportRunId then Exit(False);
      IsTurn := FExportNextCommit = OrderIdx;
    finally
      LeaveCriticalsection(FExportLock);
    end;
    if IsTurn then
      Exit(True);
    if FExportCancel then
      Exit(False);
    Sleep(20);
  end;
end;

procedure TMainForm.FinishExportCommitTurn(RunId: Integer);
begin
  EnterCriticalsection(FExportLock);
  try
    if RunId = FExportRunId then
      Inc(FExportNextCommit);
  finally
    LeaveCriticalsection(FExportLock);
  end;
end;

procedure TMainForm.ExportWorkerJobDone(RunId, OrderIdx, FrameIdx: Integer;
  Outcome: TExportOutcome; const Err: String;
  BuildMs, LoadMs, CropMs, AdjustMs, SaveMs,
  TotalMs: Int64);
var
  StripIdx, Row, Page, LastVisibleStrip, FollowFrameIdx: Integer;
  FlushUI, ShowTiming: Boolean;
  LowerErr: String;
begin
  if RunId <> FExportRunId then Exit;

  Inc(FExportDoneCount);
  FExportLastDoneCount := FExportDoneCount;
  FExportLastProgressTick := GetTickCount64;
  Inc(FExportBuildMs, BuildMs);
  Inc(FExportLoadMs, LoadMs);
  Inc(FExportCropMs, CropMs);
  Inc(FExportAdjustMs, AdjustMs);
  Inc(FExportSaveMs, SaveMs);
  Inc(FExportTotalMs, TotalMs);
  case Outcome of
    eoExported: Inc(FExportedCount);
    eoSkipped: Inc(FExportSkippedCount);
    eoFailed:
      begin
        Inc(FExportFailedCount);
        AddExportFailure(FrameIdx, Err);
      end;
  end;
  if (Outcome in [eoExported, eoSkipped]) and
     (FrameIdx >= 0) and (FrameIdx <= High(FFrames)) then
    FFrames[FrameIdx].IsExported := True;

  FollowFrameIdx := -1;
  EnterCriticalsection(FExportLock);
  try
    if (OrderIdx >= 0) and (OrderIdx <= High(FExportJobDone)) then
      FExportJobDone[OrderIdx] := True;

    while (FExportFollowOrderIdx <= High(FExportJobDone)) and
          FExportJobDone[FExportFollowOrderIdx] do
    begin
      if (FExportFollowOrderIdx <= High(FExportJobs)) then
        FollowFrameIdx := FExportJobs[FExportFollowOrderIdx].FrameIdx;
      Inc(FExportFollowOrderIdx);
    end;

  finally
    LeaveCriticalsection(FExportLock);
  end;

  if Outcome = eoFailed then
  begin
    LowerErr := LowerCase(Err);
    if (Pos('windows error 8', LowerErr) > 0) or
       (Pos('reallocbitmap', LowerErr) > 0) or
       (Pos('out of memory', LowerErr) > 0) or
       (Pos('access violation', LowerErr) > 0) then
    begin
      FExportCancel := True;
      EnterCriticalsection(FExportLock);
      try
        FExportNextJob := Length(FExportJobs);
      finally
        LeaveCriticalsection(FExportLock);
      end;
    end;
  end;

  if Assigned(FChkExportFollowPage) and FChkExportFollowPage.Checked and
     (FollowFrameIdx >= 0) and (FollowFrameIdx <= High(FFrames)) then
  begin
    StripIdx := FrameLeadStrip(FFrames[FollowFrameIdx], FRollData.LengthLines);
    LastVisibleStrip := FStripView.FirstStrip +
      (FStripView.RowsPerPage * FStripView.StripsPerRow) - 1;
    if (StripIdx < FStripView.FirstStrip) or (StripIdx > LastVisibleStrip) then
    begin
      Row := StripIdx div Max(1, FStripView.StripsPerRow);
      Page := Row div Max(1, FStripView.RowsPerPage);
      FStripView.GotoPage(Page);
    end;
  end;

  FProgressExport.Position := Min(FProgressExport.Max, FExportDoneCount);
  ShowTiming := Assigned(FChkExportTiming) and FChkExportTiming.Checked and
    (FExportDoneCount > 0);
  if Outcome = eoFailed then
    FLblExportStatus.Caption := Format('%d/%d  failed: %d'#13#10'%s',
      [FExportDoneCount, FProgressExport.Max, FExportFailedCount, Err])
  else if ShowTiming then
    FLblExportStatus.Caption := Format('%d/%d  ok:%d skip:%d fail:%d'#13#10'avg L/C/A/S/T: %d/%d/%d/%d/%d ms',
      [FExportDoneCount, FProgressExport.Max, FExportedCount,
       FExportSkippedCount, FExportFailedCount,
       FExportLoadMs div FExportDoneCount,
       FExportCropMs div FExportDoneCount,
       FExportAdjustMs div FExportDoneCount,
       FExportSaveMs div FExportDoneCount,
       FExportTotalMs div FExportDoneCount])
  else
    FLblExportStatus.Caption := Format('%d/%d  ok:%d skip:%d fail:%d',
      [FExportDoneCount, FProgressExport.Max, FExportedCount,
       FExportSkippedCount, FExportFailedCount]);

  FlushUI := (FExportDoneCount >= FProgressExport.Max);
  if Assigned(FChkExportBatchUI) and FChkExportBatchUI.Checked then
    FlushUI := FlushUI or ((FExportDoneCount mod EXPORT_UI_FLUSH_INTERVAL) = 0)
  else
    FlushUI := True;
  if FlushUI then
  begin
    FStripView.TrimBitmapCacheToCurrentPage;
    FStripView.UpdateFrames(FFrames);
  end;
end;

procedure TMainForm.ExportWorkerDone(RunId: Integer);
var
  i, FrameIdx: Integer;
begin
  if RunId <> FExportRunId then Exit;

  Dec(FExportActiveWorkers);
  if FExportActiveWorkers > 0 then Exit;

  FExportRunning := False;
  for i := 0 to High(FExportJobs) do
  begin
    FrameIdx := FExportJobs[i].FrameIdx;
    if (FrameIdx >= 0) and (FrameIdx <= High(FFrames)) and
       FileExists(FExportJobs[i].FullPath) then
      FFrames[FrameIdx].IsExported := True;
  end;
  FStripView.UpdateFrames(FFrames);
  FBtnExportStart.Enabled := True;
  if Assigned(FBtnPrepareFolders) then
    FBtnPrepareFolders.Enabled := True;
  if Assigned(FBtnReExportFailed) then
    FBtnReExportFailed.Enabled := Length(FExportFailedFrames) > 0;
  FBtnExportPause.Enabled := False;
  FBtnExportPause.Caption := 'Pause';
  FBtnExportStop.Enabled := False;

  if FExportCancel then
    FLblExportStatus.Caption := Format('Stopped. ok:%d skip:%d fail:%d',
      [FExportedCount, FExportSkippedCount, FExportFailedCount])
  else if Assigned(FChkExportTiming) and FChkExportTiming.Checked and
          (FExportDoneCount > 0) then
    FLblExportStatus.Caption := Format('Complete. ok:%d skip:%d fail:%d'#13#10'avg L/C/A/S/T: %d/%d/%d/%d/%d ms',
      [FExportedCount, FExportSkippedCount, FExportFailedCount,
       FExportLoadMs div FExportDoneCount,
       FExportCropMs div FExportDoneCount,
       FExportAdjustMs div FExportDoneCount,
       FExportSaveMs div FExportDoneCount,
       FExportTotalMs div FExportDoneCount])
  else
    FLblExportStatus.Caption := Format('Complete. ok:%d skip:%d fail:%d',
      [FExportedCount, FExportSkippedCount, FExportFailedCount]);
  if Assigned(FExportWatchdogTimer) then
    FExportWatchdogTimer.Enabled := False;
  UpdateStatus;
  if (not FExportCancel) and (Length(FExportFailedFrames) > 0) then
    ShowMessage(Format('Export completed with %d failed frame(s).'#13#10#13#10'%s',
      [Length(FExportFailedFrames), ExportFailureSummary]));
end;

procedure TMainForm.ClearExportFailures;
begin
  SetLength(FExportFailedFrames, 0);
  SetLength(FExportFailedErrors, 0);
  if Assigned(FBtnReExportFailed) then
    FBtnReExportFailed.Enabled := False;
end;

procedure TMainForm.AddExportFailure(FrameIdx: Integer; const Err: String);
var
  Idx: Integer;
begin
  Idx := Length(FExportFailedFrames);
  SetLength(FExportFailedFrames, Idx + 1);
  SetLength(FExportFailedErrors, Idx + 1);
  FExportFailedFrames[Idx] := FrameIdx;
  FExportFailedErrors[Idx] := Err;
  if Assigned(FBtnReExportFailed) and (not FExportRunning) then
    FBtnReExportFailed.Enabled := True;
end;

function TMainForm.ExportFailureSummary: String;
var
  i, LimitCount: Integer;
begin
  Result := '';
  LimitCount := Min(Length(FExportFailedFrames), 12);
  for i := 0 to LimitCount - 1 do
  begin
    if Result <> '' then Result := Result + LineEnding;
    Result := Result + Format('Frame %d: %s',
      [FExportFailedFrames[i] + 1, FExportFailedErrors[i]]);
  end;
  if Length(FExportFailedFrames) > LimitCount then
    Result := Result + LineEnding + Format('...and %d more.',
      [Length(FExportFailedFrames) - LimitCount]);
end;

function TMainForm.BuildExportJobsForCurrentScope(out Err: String): Boolean;
var
  ExportOrder: array of Integer;
  SelectedOnly, ReverseOrder: Boolean;
  i, FrameIdx: Integer;
  FolderPath, FileName, FullPath: String;

  procedure AddFrameToOrder(AFrameIdx: Integer);
  begin
    if (AFrameIdx < 0) or (AFrameIdx > High(FFrames)) then Exit;
    SetLength(ExportOrder, Length(ExportOrder) + 1);
    ExportOrder[High(ExportOrder)] := AFrameIdx;
  end;

begin
  Result := False;
  Err := '';
  SetLength(FExportJobs, 0);
  SetLength(FExportJobDone, 0);

  if not FRollData.Loaded then
  begin
    Err := 'No roll is loaded.';
    Exit;
  end;

  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  SortFramesByPosition(FFrames);
  ExportOrder := nil;

  if FExportRetryFailedOnly then
  begin
    for i := 0 to High(FExportFailedFrames) do
      AddFrameToOrder(FExportFailedFrames[i]);
    if Length(ExportOrder) = 0 then
    begin
      Err := 'There are no failed frames to re-export.';
      Exit;
    end;
  end
  else
  begin
    SelectedOnly := False;
    ReverseOrder := False;
    if Assigned(FRbProcSelected) then
      SelectedOnly := FRbProcSelected.Checked;
    if Assigned(FChkReverseOrder) then
      ReverseOrder := FChkReverseOrder.Checked;
    if SelectedOnly then
    begin
      for i := 0 to High(FFrames) do
        if FFrames[i].IsSelected then
          AddFrameToOrder(i);
    end
    else if ReverseOrder then
    begin
      for i := High(FFrames) downto 0 do
        AddFrameToOrder(i);
    end
    else
      for i := 0 to High(FFrames) do
        AddFrameToOrder(i);
  end;

  if Length(ExportOrder) = 0 then
  begin
    Err := 'No frames selected for export.';
    Exit;
  end;

  for i := 0 to High(ExportOrder) do
  begin
    FrameIdx := ExportOrder[i];
    if not ExportPathForFrame(FrameIdx, FolderPath, FileName, FullPath, Err) then
      Exit;
    SetLength(FExportJobs, Length(FExportJobs) + 1);
    FExportJobs[High(FExportJobs)].OrderIdx := i;
    FExportJobs[High(FExportJobs)].FrameIdx := FrameIdx;
    FExportJobs[High(FExportJobs)].FolderPath := FolderPath;
    FExportJobs[High(FExportJobs)].FullPath := FullPath;
  end;

  Result := True;
end;

function TMainForm.PrecreateCurrentExportJobFolders(out PreparedCount: Integer;
  out Err: String): Boolean;
var
  Folders: TStringList;
  JobIdx, FolderIdx: Integer;
  FolderErr: String;
begin
  Result := False;
  PreparedCount := 0;
  Err := '';
  Folders := TStringList.Create;
  try
    Folders.Sorted := True;
    Folders.Duplicates := dupIgnore;
    for JobIdx := 0 to High(FExportJobs) do
      Folders.Add(FExportJobs[JobIdx].FolderPath);
    PreparedCount := Folders.Count;

    if Assigned(FLblExportStatus) then
    begin
      FLblExportStatus.Caption := Format('Preparing %d output folder(s)...',
        [Folders.Count]);
      Application.ProcessMessages;
    end;

    for FolderIdx := 0 to Folders.Count - 1 do
    begin
      FolderErr := '';
      if not EnsureDirectoryReady(Folders[FolderIdx], FolderErr) then
      begin
        Err := FolderErr;
        Exit;
      end;
    end;

    Result := True;
  finally
    Folders.Free;
  end;
end;

function TMainForm.PrepareExportFoldersForCurrentScope(out PreparedCount: Integer;
  out Err: String): Boolean;
begin
  PreparedCount := 0;
  Result := BuildExportJobsForCurrentScope(Err);
  if Result then
    Result := PrecreateCurrentExportJobFolders(PreparedCount, Err);
end;

procedure TMainForm.StartThreadedExport;
var
  Settings: TExportSettings;
  i, WorkerCount, LoadThreads, ProcessThreads, RequestedCacheLimit: Integer;
  PreparedCount: Integer;
  Err: String;
begin
  if not FRollData.Loaded then Exit;
  if FExportRunning then Exit;
  if Assigned(FPreviewForm) then
    FPreviewForm.Close;
  StoreAdjustmentControlsToRoll;
  StoreExportNamingControlsToRoll;
  FRollData.JpgQuality := FSpinQuality.Value;
  if (FRollData.StriplightExportEncoder = EXPORT_ENCODER_TURBOJPEG) and
     (not TurboJPEGAvailable) then
  begin
    ShowMessage(TurboJPEGStatus);
    Exit;
  end;

  if not BuildExportJobsForCurrentScope(Err) then
  begin
    ShowMessage('Export path error: ' + Err);
    Exit;
  end;
  if Assigned(FChkPrecreateFolders) and FChkPrecreateFolders.Checked then
    if not PrecreateCurrentExportJobFolders(PreparedCount, Err) then
    begin
      ShowMessage('Export folder error: ' + Err);
      Exit;
    end;

  for i := 0 to High(FFrames) do
    FFrames[i].IsExported := False;
  FStripView.UpdateFrames(FFrames);
  FStripView.TrimBitmapCacheToCurrentPage;

  Settings.Roll := FRollData;
  Settings.Frames := Copy(FFrames, 0, Length(FFrames));
  Settings.SourceRotateCW := FStripView.RotateCW;
  Settings.JpgQuality := Max(1, Min(100, FSpinQuality.Value));
  Settings.JpgGrayscale := True;
  if Assigned(FChkExportGrayscale) then
    Settings.JpgGrayscale := FChkExportGrayscale.Checked;
  Settings.JpgProgressive := False;
  if Assigned(FChkExportProgressive) then
    Settings.JpgProgressive := FChkExportProgressive.Checked;
  Settings.JpgEncoder := EXPORT_ENCODER_BUILTIN;
  if Assigned(FComboExportEncoder) then
    Settings.JpgEncoder := FComboExportEncoder.ItemIndex;
  Settings.CacheLimit := 4;
  if Assigned(FSpinExportCache) then
    Settings.CacheLimit := Max(1, Min(16, FSpinExportCache.Value));
  RequestedCacheLimit := Settings.CacheLimit;
  Settings.SkipExisting := False;
  if Assigned(FChkSkipExisting) then
    Settings.SkipExisting := FChkSkipExisting.Checked;
  if FExportRetryFailedOnly then
    Settings.SkipExisting := False;
  Settings.AllowPreviewFallback := False;
  if Assigned(FChkAllowPreviewExport) then
    Settings.AllowPreviewFallback := FChkAllowPreviewExport.Checked;
  Settings.LocalTempStage := False;
  if Assigned(FChkExportLocalTemp) then
    Settings.LocalTempStage := FChkExportLocalTemp.Checked;
  Settings.GlobalRotation := CurrentProcessRotation;
  Settings.GlobalFlipH := False;
  if Assigned(FChkMirror) then
    Settings.GlobalFlipH := FChkMirror.Checked;
  Settings.GlobalFlipV := False;
  Settings.GlobalNegative := False;
  if Assigned(FChkNegative) then
    Settings.GlobalNegative := FChkNegative.Checked;
  Settings.GlobalMethod := 0;
  if Assigned(FComboAdjustMethod) then
    Settings.GlobalMethod := FComboAdjustMethod.ItemIndex;
  Settings.GlobalFlags := CurrentAdjustmentFlags;
  Settings.GlobalContrast := FTrackContrast.Position;
  Settings.GlobalBrightness := FTrackBrightness.Position;
  Settings.GlobalGamma := FTrackGamma.Position;
  Settings.GlobalSharpness := 0;
  if Assigned(FTrackSharpness) then
    Settings.GlobalSharpness := FTrackSharpness.Position;
  Settings.GlobalSharpnessMode := 0;
  if Assigned(FComboSharpnessMode) then
    Settings.GlobalSharpnessMode := FComboSharpnessMode.ItemIndex;

  LoadThreads := 1;
  ProcessThreads := 1;
  if Assigned(FSpinExportLoadThreads) then
    LoadThreads := Max(1, Min(16, FSpinExportLoadThreads.Value));
  if Assigned(FSpinExportProcessThreads) then
    ProcessThreads := Max(1, Min(16, FSpinExportProcessThreads.Value));
  WorkerCount := Min(Length(FExportJobs), Max(LoadThreads, ProcessThreads));
  if WorkerCount < 1 then WorkerCount := 1;
  Settings.CacheLimit := Max(1, (RequestedCacheLimit + WorkerCount - 1) div WorkerCount);

  EnterCriticalsection(FExportLock);
  try
    Inc(FExportRunId);
    SetLength(FExportJobDone, Length(FExportJobs));
    FExportNextJob := 0;
    FExportNextCommit := 0;
    FExportBatchStart := 0;
    FExportBatchEnd := Min(High(FExportJobs), EXPORT_JOB_BATCH_SIZE - 1);
    FExportFollowOrderIdx := 0;
    FExportActiveWorkers := WorkerCount;
    FExportDoneCount := 0;
    FExportedCount := 0;
    FExportSkippedCount := 0;
    FExportFailedCount := 0;
    FExportBuildMs := 0;
    FExportLoadMs := 0;
    FExportCropMs := 0;
    FExportAdjustMs := 0;
    FExportSaveMs := 0;
    FExportTotalMs := 0;
  finally
    LeaveCriticalsection(FExportLock);
  end;

  FExportCancel := False;
  FExportPaused := False;
  FExportRunning := True;
  ClearExportFailures;
  FExportLastDoneCount := 0;
  FExportLastProgressTick := GetTickCount64;
  FExportTracePath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'Striplight_export_debug.log';
  FExportLastTrace := '';
  DeleteFile(FExportTracePath);
  ExportTrace(FExportRunId, 0, -1, -1, 'export-start',
    Format('%d worker(s), %d frame(s), load %d, process %d, strict batch %d',
      [WorkerCount, Length(FExportJobs), LoadThreads, ProcessThreads,
       EXPORT_JOB_BATCH_SIZE]));
  FBtnExportStart.Enabled := False;
  if Assigned(FBtnPrepareFolders) then
    FBtnPrepareFolders.Enabled := False;
  if Assigned(FBtnReExportFailed) then
    FBtnReExportFailed.Enabled := False;
  FBtnExportPause.Enabled := True;
  FBtnExportPause.Caption := 'Pause';
  FBtnExportStop.Enabled := True;
  FProgressExport.Min := 0;
  FProgressExport.Max := Length(FExportJobs);
  FProgressExport.Position := 0;
  FLblExportStatus.Caption := Format('Started: %d worker(s), %d frame(s)'#13#10'load/process %d/%d  cache %d/%d',
    [WorkerCount, Length(FExportJobs), LoadThreads, ProcessThreads,
     RequestedCacheLimit, Settings.CacheLimit]);
  if Assigned(FExportWatchdogTimer) then
    FExportWatchdogTimer.Enabled := True;

  for i := 1 to WorkerCount do
    TExportWorkerThread.Create(Self, Settings).Start;
end;

procedure TMainForm.OnExportStart(Sender: TObject);
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
  ExportOrder: array of Integer;
  Exported, Skipped, Failed, OrderIdx, FrameIdx: Integer;
  LoadThreads, ProcessThreads: Integer;
  FolderPath, FileName, FullPath, Err: String;
  Bmp: TBGRABitmap;
  SourceCache: TStringList;
  SkipExisting: Boolean;
  SourceCacheLimit: Integer;
  LocalTempStage: Boolean;
  BuildMs, SaveMs, TotalMs: Int64;
  StartMs, BuildDoneMs, SaveStartMs, SaveDoneMs: QWord;

  function ClampInt(Value, Lo, Hi: Integer): Integer;
  begin
    Result := Max(Lo, Min(Hi, Value));
  end;

  function CeilDiv64(Value, Divisor: Int64): Integer;
  begin
    if Divisor <= 0 then Exit(1);
    if Value <= 0 then Exit(1);
    Result := Integer((Value + Divisor - 1) div Divisor);
    if Result < 1 then Result := 1;
  end;

  function FrameStripFilesAvailable(const F: TFrameRecord; FirstStrip, LastStrip: Integer): Boolean;
  var
    S: Integer;
  begin
    Result := True;
    for S := FirstStrip to LastStrip do
      if not FileExists(StripFilePath(FRollData, S)) then
        Exit(False);
  end;

  procedure SaveJpeg(ABitmap: TBGRABitmap; const Path: String);
  var
    Writer: TFPWriterJPEG;
    Err: String;
  begin
    if FRollData.StriplightExportEncoder = EXPORT_ENCODER_TURBOJPEG then
    begin
      if SaveTurboJPEG(ABitmap, Path, Max(1, Min(100, FSpinQuality.Value)),
        FRollData.StriplightExportGrayscale,
        FRollData.StriplightExportProgressive, Err) then
        Exit;
      raise Exception.Create(Err);
    end;

    Writer := TFPWriterJPEG.Create;
    try
      Writer.CompressionQuality := Max(1, Min(100, FSpinQuality.Value));
      Writer.GrayScale := FRollData.StriplightExportGrayscale;
      Writer.ProgressiveEncoding := FRollData.StriplightExportProgressive;
      ABitmap.SaveToFile(Path, Writer);
    finally
      Writer.Free;
    end;
  end;

  procedure SaveJpegStaged(ABitmap: TBGRABitmap; const Path: String);
  var
    TempDir, TempPath: String;
    InStream, OutStream: TFileStream;
  begin
    if not LocalTempStage then
    begin
      SaveJpeg(ABitmap, Path);
      Exit;
    end;

    TempDir := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'Striplight_export_temp';
    ForceDirectories(TempDir);
    TempPath := IncludeTrailingPathDelimiter(TempDir) +
      'frame_single_' + IntToStr(GetTickCount64) + '.jpg';

    SaveJpeg(ABitmap, TempPath);
    try
      InStream := TFileStream.Create(TempPath, fmOpenRead or fmShareDenyNone);
      try
        OutStream := TFileStream.Create(Path, fmCreate);
        try
          OutStream.CopyFrom(InStream, 0);
        finally
          OutStream.Free;
        end;
      finally
        InStream.Free;
      end;
    finally
      DeleteFile(TempPath);
    end;
  end;

  procedure FreeSourceCache;
  var
    i: Integer;
  begin
    if not Assigned(SourceCache) then Exit;
    for i := 0 to SourceCache.Count - 1 do
      SourceCache.Objects[i].Free;
    FreeAndNil(SourceCache);
  end;

  function CachedOrientedSource(const SourcePath: String; out Err: String): TBGRABitmap;
  var
    CacheIdx: Integer;
    RawBmp, OrientedBmp: TBGRABitmap;
  begin
    Result := nil;
    Err := '';
    CacheIdx := SourceCache.IndexOf(SourcePath);
    if CacheIdx >= 0 then
      Exit(TBGRABitmap(SourceCache.Objects[CacheIdx]));

    RawBmp := nil;
    OrientedBmp := nil;
    try
      RawBmp := TBGRABitmap.Create(SourcePath);
      if FStripView.RotateCW then
      begin
        OrientedBmp := RawBmp.RotateCW;
        OrientedBmp.HorizontalFlip;
      end
      else
        OrientedBmp := RawBmp.RotateCCW;
      RawBmp.Free;
      RawBmp := nil;

      while SourceCache.Count >= SourceCacheLimit do
      begin
        SourceCache.Objects[0].Free;
        SourceCache.Delete(0);
      end;
      SourceCache.AddObject(SourcePath, OrientedBmp);
      Result := OrientedBmp;
      OrientedBmp := nil;
    except
      on E: Exception do
        Err := E.Message;
    end;
    OrientedBmp.Free;
    RawBmp.Free;
  end;

  procedure WaitIfExportPaused;
  begin
    while FExportPaused and not FExportCancel do
    begin
      FLblExportStatus.Caption := Format('Export paused. Completed %d / %d.',
        [FProgressExport.Position, FProgressExport.Max]);
      Application.ProcessMessages;
      Sleep(75);
    end;
  end;

  procedure ResolveFrameProcessing(const F: TFrameRecord; out Rot: Integer;
    out FlipH, FlipV, Negative: Boolean; out Method, Flags, Contrast,
    Brightness, Gamma: Integer);
  begin
    if F.HasOverride then
    begin
      Rot := F.Rotation;
      FlipH := F.FlipH;
      FlipV := F.FlipV;
      Negative := F.Negative;
    end
    else
    begin
      Rot := CurrentProcessRotation;
      FlipH := FChkMirror.Checked;
      FlipV := False;
      Negative := FChkNegative.Checked;
    end;
    Rot := ((Rot mod 360) + 360) mod 360;
    if (Rot <> 0) and (Rot <> 90) and (Rot <> 180) and (Rot <> 270) then
      Rot := 0;

    Method := 0;
    if Assigned(FComboAdjustMethod) then
      Method := FComboAdjustMethod.ItemIndex;
    Flags := CurrentAdjustmentFlags;
    Contrast := FTrackContrast.Position;
    Brightness := FTrackBrightness.Position;
    Gamma := FTrackGamma.Position;
    if (F.PerFrameContrast <> -1) or (F.PerFrameBrightness <> -1) or
       (F.PerFrameGamma <> -1) then
    begin
      Method := 1;
      Flags := 0;
      Contrast := 64;
      Brightness := 0;
      Gamma := 0;
      if F.PerFrameContrast <> -1 then Contrast := F.PerFrameContrast;
      if F.PerFrameBrightness <> -1 then Brightness := F.PerFrameBrightness;
      if F.PerFrameGamma <> -1 then Gamma := F.PerFrameGamma;
    end
    else
    begin
      if F.CustomContrast <> -1 then Contrast := F.CustomContrast;
      if F.CustomBrightness <> -1 then Brightness := F.CustomBrightness;
      if F.CustomGamma <> -1 then Gamma := F.CustomGamma;
    end;
  end;

  procedure ApplyNegative(ABitmap: TBGRABitmap);
  var
    X, Y: Integer;
    P: PBGRAPixel;
  begin
    for Y := 0 to ABitmap.Height - 1 do
    begin
      P := ABitmap.ScanLine[Y];
      for X := 0 to ABitmap.Width - 1 do
      begin
        P^.red := 255 - P^.red;
        P^.green := 255 - P^.green;
        P^.blue := 255 - P^.blue;
        Inc(P);
      end;
    end;
  end;

  procedure ApplyGrayAdjustment(ABitmap: TBGRABitmap; Method, Flags, Contrast,
    Brightness, Gamma: Integer);
  var
    X, Y: Integer;
    LUT: array[0..255] of Byte;
    P: PBGRAPixel;

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
    for Y := 0 to ABitmap.Height - 1 do
    begin
      P := ABitmap.ScanLine[Y];
      for X := 0 to ABitmap.Width - 1 do
      begin
        P^.red := LUT[P^.red];
        P^.green := LUT[P^.green];
        P^.blue := LUT[P^.blue];
        Inc(P);
      end;
    end;
  end;

  function AdjustmentIsNoOp(Method, Flags, Contrast, Brightness, Gamma: Integer): Boolean;
  begin
    if Flags <> 0 then Exit(False);
    case Method of
      1, 4:
        Result := (Contrast = 64) and (Brightness = 0) and (Gamma = 0);
      2, 3:
        Result := False;
    else
      Result := (Contrast = 0) and (Brightness = 0) and (Gamma = 100);
    end;
  end;

  function BuildFrameBitmap(FrameIdx: Integer; out ABitmap: TBGRABitmap; out Err: String): Boolean;
  var
    F: TFrameRecord;
    FirstStrip, LastStrip, StripIdx, DS: Integer;
    UseFullSource: Boolean;
    LocalLead, LocalTrail: Int64;
    SrcLeft, SrcRight, SrcTop, SrcBottom: Integer;
    SourceW, SourceH, TotalW, MaxH, OffsetX: Integer;
    SourcePath: String;
    Source, CropBmp, SegmentBmp, ProcessedBmp, TempBmp: TBGRABitmap;
    SegmentRects: array of TRect;
    Rot, Method, Flags, Contrast, Brightness, Gamma: Integer;
    FlipH, FlipV, Negative: Boolean;
    AllowPreviewFallback: Boolean;
  begin
    Result := False;
    ABitmap := nil;
    Err := '';
    F := FFrames[FrameIdx];
    DS := Max(1, FRollData.PreviewDownScale);
    FirstStrip := Max(0, FrameLeadStrip(F, FRollData.LengthLines));
    LastStrip := Min(FRollData.StripCount - 1, FrameTrailStrip(F, FRollData.LengthLines));
    if LastStrip < FirstStrip then LastStrip := FirstStrip;
    UseFullSource := FrameStripFilesAvailable(F, FirstStrip, LastStrip);
    AllowPreviewFallback := False;
    if Assigned(FChkAllowPreviewExport) then
      AllowPreviewFallback := FChkAllowPreviewExport.Checked;
    if (not UseFullSource) and (not AllowPreviewFallback) then
    begin
      Err := 'Missing full strip source for frame; preview fallback is disabled.';
      Exit;
    end;

    SetLength(SegmentRects, LastStrip - FirstStrip + 1);
    TotalW := 0;
    MaxH := 0;
    for StripIdx := FirstStrip to LastStrip do
    begin
      LocalLead := F.LeadEdge - Int64(StripIdx) * FRollData.LengthLines;
      LocalTrail := F.TrailEdge - Int64(StripIdx) * FRollData.LengthLines;
      if LocalLead < 0 then LocalLead := 0;
      if LocalTrail > FRollData.LengthLines then LocalTrail := FRollData.LengthLines;
      if LocalTrail <= LocalLead then Continue;

      if UseFullSource then
      begin
        SourceW := Max(1, FRollData.WidthPixels);
        SourceH := Max(1, FRollData.LengthLines);
        SrcLeft := ClampInt(LocalLead, 0, SourceH - 1);
        SrcRight := ClampInt(LocalTrail, SrcLeft + 1, SourceH);
        SrcTop := ClampInt(F.LeftEdge, 0, SourceW - 1);
        SrcBottom := ClampInt(F.RightEdge, SrcTop + 1, SourceW);
      end
      else
      begin
        SourceW := CeilDiv64(FRollData.WidthPixels, DS);
        SourceH := CeilDiv64(FRollData.LengthLines, DS);
        SrcLeft := ClampInt(LocalLead div DS, 0, SourceH - 1);
        SrcRight := ClampInt((LocalTrail + DS - 1) div DS, SrcLeft + 1, SourceH);
        SrcTop := ClampInt(F.LeftEdge div DS, 0, SourceW - 1);
        SrcBottom := ClampInt((F.RightEdge + DS - 1) div DS, SrcTop + 1, SourceW);
      end;
      SegmentRects[StripIdx - FirstStrip] := Rect(SrcLeft, SrcTop, SrcRight, SrcBottom);
      Inc(TotalW, SrcRight - SrcLeft);
      MaxH := Max(MaxH, SrcBottom - SrcTop);
    end;

    if (TotalW <= 0) or (MaxH <= 0) then
    begin
      Err := 'Frame has no visible image area.';
      Exit;
    end;

    ABitmap := TBGRABitmap.Create(TotalW, MaxH, BGRA(0, 0, 0));
    try
      OffsetX := 0;
      for StripIdx := FirstStrip to LastStrip do
      begin
        SrcLeft := SegmentRects[StripIdx - FirstStrip].Left;
        SrcTop := SegmentRects[StripIdx - FirstStrip].Top;
        SrcRight := SegmentRects[StripIdx - FirstStrip].Right;
        SrcBottom := SegmentRects[StripIdx - FirstStrip].Bottom;
        if (SrcRight <= SrcLeft) or (SrcBottom <= SrcTop) then Continue;

        if UseFullSource then
          SourcePath := StripFilePath(FRollData, StripIdx)
        else
          SourcePath := PreviewFilePath(FRollData, StripIdx);
        if not FileExists(SourcePath) then
        begin
          Err := 'Missing source image: ' + SourcePath;
          Exit;
        end;

        Source := CachedOrientedSource(SourcePath, Err);
        if not Assigned(Source) then
          Exit;
        CropBmp := nil;
        SegmentBmp := nil;
        try
          SrcLeft := ClampInt(SrcLeft, 0, Source.Width - 1);
          SrcRight := ClampInt(SrcRight, SrcLeft + 1, Source.Width);
          SrcTop := ClampInt(SrcTop, 0, Source.Height - 1);
          SrcBottom := ClampInt(SrcBottom, SrcTop + 1, Source.Height);
          CropBmp := Source.GetPart(Rect(SrcLeft, SrcTop, SrcRight, SrcBottom));
          SegmentBmp := CropBmp;
          CropBmp := nil;
          ABitmap.PutImage(OffsetX, 0, SegmentBmp, dmSet);
          Inc(OffsetX, SegmentBmp.Width);
        finally
          SegmentBmp.Free;
          CropBmp.Free;
        end;
      end;

      ResolveFrameProcessing(F, Rot, FlipH, FlipV, Negative, Method, Flags,
        Contrast, Brightness, Gamma);
      ProcessedBmp := nil;
      TempBmp := nil;
      try
        case Rot of
          90: ProcessedBmp := ABitmap.RotateCW;
          180:
            begin
              TempBmp := ABitmap.RotateCW;
              ProcessedBmp := TempBmp.RotateCW;
            end;
          270: ProcessedBmp := ABitmap.RotateCCW;
        else
          ProcessedBmp := ABitmap.GetPart(Rect(0, 0, ABitmap.Width, ABitmap.Height));
        end;
        if FlipH then ProcessedBmp.HorizontalFlip;
        if FlipV then ProcessedBmp.VerticalFlip;
        if not AdjustmentIsNoOp(Method, Flags, Contrast, Brightness, Gamma) then
          ApplyGrayAdjustment(ProcessedBmp, Method, Flags, Contrast, Brightness, Gamma);
        if Negative then ApplyNegative(ProcessedBmp);
        if Assigned(FTrackSharpness) then
          ApplySharpnessFilter(ProcessedBmp,
            IfThen(Assigned(FComboSharpnessMode), FComboSharpnessMode.ItemIndex, 0),
            FTrackSharpness.Position);
        FreeAndNil(ABitmap);
        ABitmap := ProcessedBmp;
        ProcessedBmp := nil;
      finally
        TempBmp.Free;
        ProcessedBmp.Free;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        Err := E.Message;
        FreeAndNil(ABitmap);
      end;
    end;
  end;

  procedure AddFrameToOrder(FrameIdx: Integer);
  begin
    SetLength(ExportOrder, Length(ExportOrder) + 1);
    ExportOrder[High(ExportOrder)] := FrameIdx;
  end;

  procedure BuildExportOrder;
  var
    i: Integer;
    SelectedOnly, ReverseOrder: Boolean;
  begin
    ExportOrder := nil;
    FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
    SortFramesByPosition(FFrames);
    SelectedOnly := False;
    ReverseOrder := False;
    if Assigned(FRbProcSelected) then
      SelectedOnly := FRbProcSelected.Checked;
    if Assigned(FChkReverseOrder) then
      ReverseOrder := FChkReverseOrder.Checked;

    if SelectedOnly then
    begin
      for i := 0 to High(FFrames) do
        if FFrames[i].IsSelected then
          AddFrameToOrder(i);
    end
    else if ReverseOrder then
    begin
      for i := High(FFrames) downto 0 do
        AddFrameToOrder(i);
    end
    else
      for i := 0 to High(FFrames) do
        AddFrameToOrder(i);
  end;

  procedure FollowExportPage(FrameIdx: Integer);
  var
    StripIdx, Row, Page, LastVisibleStrip: Integer;
  begin
    if not (Assigned(FChkExportFollowPage) and FChkExportFollowPage.Checked) then Exit;
    if (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;
    StripIdx := FrameLeadStrip(FFrames[FrameIdx], FRollData.LengthLines);
    LastVisibleStrip := FStripView.FirstStrip +
      (FStripView.RowsPerPage * FStripView.StripsPerRow) - 1;
    if (StripIdx < FStripView.FirstStrip) or (StripIdx > LastVisibleStrip) then
    begin
      Row := StripIdx div Max(1, FStripView.StripsPerRow);
      Page := Row div Max(1, FStripView.RowsPerPage);
      FStripView.GotoPage(Page);
    end;
  end;

begin
  if not FRollData.Loaded then Exit;
  if FExportRunning then Exit;
  if Assigned(FPreviewForm) then
    FPreviewForm.Close;
  LoadThreads := 1;
  ProcessThreads := 1;
  if Assigned(FSpinExportLoadThreads) then
    LoadThreads := Max(1, Min(16, FSpinExportLoadThreads.Value));
  if Assigned(FSpinExportProcessThreads) then
    ProcessThreads := Max(1, Min(16, FSpinExportProcessThreads.Value));
  if Max(LoadThreads, ProcessThreads) >= 1 then
  begin
    FExportRetryFailedOnly := False;
    StartThreadedExport;
    Exit;
  end;
  StoreAdjustmentControlsToRoll;
  StoreExportNamingControlsToRoll;
  FRollData.JpgQuality := FSpinQuality.Value;
  if (FRollData.StriplightExportEncoder = EXPORT_ENCODER_TURBOJPEG) and
     (not TurboJPEGAvailable) then
  begin
    ShowMessage(TurboJPEGStatus);
    Exit;
  end;
  BuildExportOrder;
  if Length(ExportOrder) = 0 then
  begin
    ShowMessage('No frames selected for export.');
    Exit;
  end;
  for OrderIdx := 0 to High(FFrames) do
    FFrames[OrderIdx].IsExported := False;
  FStripView.UpdateFrames(FFrames);

  FExportCancel := False;
  FBtnExportStart.Enabled := False;
  FBtnExportPause.Enabled := True;
  FBtnExportPause.Caption := 'Pause';
  FBtnExportStop.Enabled := True;
  FProgressExport.Min := 0;
  FProgressExport.Max := Length(ExportOrder);
  FProgressExport.Position := 0;
  Exported := 0;
  Skipped := 0;
  Failed := 0;
  SkipExisting := False;
  if Assigned(FChkSkipExisting) then
    SkipExisting := FChkSkipExisting.Checked;
  SourceCacheLimit := 4;
  if Assigned(FSpinExportCache) then
    SourceCacheLimit := Max(1, Min(16, FSpinExportCache.Value));
  LocalTempStage := Assigned(FChkExportLocalTemp) and FChkExportLocalTemp.Checked;
  BuildMs := 0;
  SaveMs := 0;
  TotalMs := 0;
  SourceCache := TStringList.Create;

  try
    for OrderIdx := 0 to High(ExportOrder) do
    begin
      WaitIfExportPaused;
      if FExportCancel then Break;
      FrameIdx := ExportOrder[OrderIdx];
      FLblExportStatus.Caption := Format('Exporting frame %d / %d...',
        [OrderIdx + 1, Length(ExportOrder)]);
      Application.ProcessMessages;

      if ExportPathForFrame(FrameIdx, FolderPath, FileName, FullPath, Err) then
      begin
        StartMs := GetTickCount64;
        if SkipExisting and FileExists(FullPath) then
        begin
          Inc(Skipped);
          FFrames[FrameIdx].IsExported := True;
        end
        else if EnsureDirectoryReady(FolderPath, Err) then
        begin
          if BuildFrameBitmap(FrameIdx, Bmp, Err) then
          begin
            BuildDoneMs := GetTickCount64;
            Inc(BuildMs, BuildDoneMs - StartMs);
            try
              SaveStartMs := GetTickCount64;
              SaveJpegStaged(Bmp, FullPath);
              SaveDoneMs := GetTickCount64;
              Inc(SaveMs, SaveDoneMs - SaveStartMs);
              Inc(TotalMs, SaveDoneMs - StartMs);
              Inc(Exported);
              FFrames[FrameIdx].IsExported := True;
            finally
              Bmp.Free;
            end;
          end
          else
            Inc(Failed);
        end
        else
          Inc(Failed);
      end
      else
        Inc(Failed);

      if FFrames[FrameIdx].IsExported then
        FollowExportPage(FrameIdx);
      FProgressExport.Position := OrderIdx + 1;
      if (not (Assigned(FChkExportBatchUI) and FChkExportBatchUI.Checked)) or
         ((OrderIdx mod 8) = 7) then
      begin
        FStripView.UpdateFrames(FFrames);
        Application.ProcessMessages;
      end;
    end;
  finally
    FreeSourceCache;
    for OrderIdx := 0 to High(ExportOrder) do
    begin
      FrameIdx := ExportOrder[OrderIdx];
      if ExportPathForFrame(FrameIdx, FolderPath, FileName, FullPath, Err) and
         FileExists(FullPath) then
        FFrames[FrameIdx].IsExported := True;
    end;
    FStripView.UpdateFrames(FFrames);
    FBtnExportStart.Enabled := True;
    FBtnExportPause.Enabled := False;
    FBtnExportPause.Caption := 'Pause';
    FBtnExportStop.Enabled := False;
  end;

  if FExportCancel then
    FLblExportStatus.Caption := Format('Export stopped. Exported %d, skipped %d, failed %d.',
      [Exported, Skipped, Failed])
  else if Assigned(FChkExportTiming) and FChkExportTiming.Checked and
          ((Exported + Skipped + Failed) > 0) then
    FLblExportStatus.Caption := Format('Export complete. Exported %d, skipped %d, failed %d. Avg build/save/total: %d/%d/%d ms.',
      [Exported, Skipped, Failed,
       BuildMs div Max(1, Exported),
       SaveMs div Max(1, Exported),
       TotalMs div Max(1, Exported)])
  else
    FLblExportStatus.Caption := Format('Export complete. Exported %d, skipped %d, failed %d.',
      [Exported, Skipped, Failed]);
  UpdateStatus;
end;

procedure TMainForm.OnPrepareExportFolders(Sender: TObject);
var
  PreparedCount: Integer;
  Err: String;
begin
  if FExportRunning then Exit;
  FExportRetryFailedOnly := False;
  StoreExportNamingControlsToRoll;
  if PrepareExportFoldersForCurrentScope(PreparedCount, Err) then
  begin
    if Assigned(FLblExportStatus) then
      FLblExportStatus.Caption := Format('Prepared %d output folder(s).',
        [PreparedCount]);
    ShowMessage(Format('Prepared %d output folder(s).', [PreparedCount]));
  end
  else
    ShowMessage('Export folder error: ' + Err);
end;

procedure TMainForm.OnReExportFailed(Sender: TObject);
begin
  if FExportRunning then Exit;
  if Length(FExportFailedFrames) = 0 then
  begin
    ShowMessage('There are no failed frames to re-export.');
    Exit;
  end;

  FExportRetryFailedOnly := True;
  try
    StartThreadedExport;
  finally
    FExportRetryFailedOnly := False;
  end;
end;

procedure TMainForm.OnExportPause(Sender: TObject);
begin
  FExportPaused := not FExportPaused;
  if FExportPaused then
  begin
    FBtnExportPause.Caption := 'Resume';
    if Assigned(FLblExportStatus) then
      FLblExportStatus.Caption := 'Pause requested.'#13#10'Current frame will finish first...';
  end
  else
  begin
    FBtnExportPause.Caption := 'Pause';
    if Assigned(FLblExportStatus) then
      FLblExportStatus.Caption := 'Resuming export...';
  end;
end;

procedure TMainForm.OnExportWatchdog(Sender: TObject);
var
  QuietMs: QWord;
begin
  if not FExportRunning then
  begin
    FExportWatchdogTimer.Enabled := False;
    Exit;
  end;

  if FExportPaused then
  begin
    FExportLastProgressTick := GetTickCount64;
    Exit;
  end;

  QuietMs := GetTickCount64 - FExportLastProgressTick;
  if QuietMs >= 120000 then
  begin
    FExportCancel := True;
    EnterCriticalsection(FExportLock);
    try
      Inc(FExportRunId);
      FExportNextJob := Length(FExportJobs);
      FExportNextCommit := High(Integer);
      FExportActiveWorkers := 0;
    finally
      LeaveCriticalsection(FExportLock);
    end;

    FExportRunning := False;
    FExportWatchdogTimer.Enabled := False;
    FBtnExportStart.Enabled := True;
    if Assigned(FBtnPrepareFolders) then
      FBtnPrepareFolders.Enabled := True;
    if Assigned(FBtnReExportFailed) then
      FBtnReExportFailed.Enabled := Length(FExportFailedFrames) > 0;
    FBtnExportPause.Enabled := False;
    FBtnExportPause.Caption := 'Pause';
    FBtnExportStop.Enabled := False;
    FLblExportStatus.Caption := Format(
      'Stalled for %d sec after %d/%d.'#13#10'Stopped. Last: %s',
      [QuietMs div 1000, FExportDoneCount, FProgressExport.Max,
       FExportLastTrace]);
  end
  else if QuietMs >= 45000 then
    FLblExportStatus.Caption := Format(
      'No completed frame for %d sec. %d/%d done.'#13#10'Last: %s',
      [QuietMs div 1000, FExportDoneCount, FProgressExport.Max,
       FExportLastTrace]);
end;

procedure TMainForm.OnExportStop(Sender: TObject);
begin
  if not FExportRunning then Exit;
  FExportCancel := True;
  FExportPaused := False;
  EnterCriticalsection(FExportLock);
  try
    Inc(FExportRunId);
    FExportNextJob := Length(FExportJobs);
    FExportNextCommit := High(Integer);
    FExportActiveWorkers := 0;
  finally
    LeaveCriticalsection(FExportLock);
  end;
  if Assigned(FExportWatchdogTimer) then
    FExportWatchdogTimer.Enabled := False;
  FExportRunning := False;
  if Assigned(FBtnExportStart) then
    FBtnExportStart.Enabled := True;
  if Assigned(FBtnPrepareFolders) then
    FBtnPrepareFolders.Enabled := True;
  if Assigned(FBtnReExportFailed) then
    FBtnReExportFailed.Enabled := Length(FExportFailedFrames) > 0;
  if Assigned(FBtnExportStop) then
    FBtnExportStop.Enabled := False;
  if Assigned(FProgressExport) then
    FProgressExport.Position := Min(FProgressExport.Position, FProgressExport.Max);
  if Assigned(FBtnExportPause) then
  begin
    FBtnExportPause.Enabled := False;
    FBtnExportPause.Caption := 'Pause';
  end;
  if Assigned(FLblExportStatus) then
    FLblExportStatus.Caption := 'Export stopped. Any stuck worker output will be ignored.';
end;

{ ============================================================ }
{ UI state helpers                                              }
{ ============================================================ }

procedure TMainForm.UpdateNavButtons;
var
  HasRoll: Boolean;
  CurPage, TotalPg: Integer;
begin
  HasRoll  := FRollData.Loaded;
  CurPage  := FStripView.CurrentPage;
  TotalPg  := FStripView.TotalPages;

  FBtnFirst.Enabled := HasRoll and (CurPage > 0);
  FBtnPrev.Enabled  := HasRoll and (CurPage > 0);
  FBtnNext.Enabled  := HasRoll and (CurPage < TotalPg - 1);
  FBtnLast.Enabled  := HasRoll and (CurPage < TotalPg - 1);

  FSpinPageJump.Enabled := HasRoll and (TotalPg > 0);
  FSpinPageJump.MaxValue := Max(1, TotalPg);
  if HasRoll and (TotalPg > 0) then
    FSpinPageJump.Value := CurPage + 1
  else
    FSpinPageJump.Value := 1;
end;

function TMainForm.GetSingleSelectedFrameIdx: Integer;
var
  i, cnt: Integer;
begin
  Result := -1;
  cnt    := 0;
  for i := 0 to High(FFrames) do
    if FFrames[i].IsSelected then
    begin
      Inc(cnt);
      Result := i;
      if cnt > 1 then begin Result := -1; Exit; end;
    end;
end;

function TMainForm.EstimateAutoAdjustmentForFrame(FrameIdx: Integer; out Contrast,
  Brightness, Gamma: Integer): Boolean;
var
  F: TFrameRecord;
  StripIdx, FirstStrip, LastStrip, DS: Integer;
  Path: String;
  Bmp: TBGRABitmap;
  LocalLead, LocalTrail: Int64;
  X1, X2, Y1, Y2, X, Y, Step, Lum, Acc, P2, P50, P98, Count, Target: Integer;
  Hist: array[0..255] of Integer;
  Pix: PBGRAPixel;
  LowNorm, HighNorm, MidNorm, Span, Scale: Double;
  MethodIdx: Integer;

  function ClampInt(Value, Lo, Hi: Integer): Integer;
  begin
    Result := Max(Lo, Min(Hi, Value));
  end;

  function Percentile(Pct: Double): Integer;
  var
    J: Integer;
  begin
    Result := 0;
    if Count <= 0 then Exit;
    Target := Max(1, Round(Count * Pct));
    Acc := 0;
    for J := 0 to 255 do
    begin
      Inc(Acc, Hist[J]);
      if Acc >= Target then
      begin
        Result := J;
        Exit;
      end;
    end;
    Result := 255;
  end;

begin
  Result := False;
  Contrast := 0;
  Brightness := 0;
  Gamma := 100;
  if (not FRollData.Loaded) or (FrameIdx < 0) or (FrameIdx > High(FFrames)) then Exit;

  FillChar(Hist, SizeOf(Hist), 0);
  Count := 0;
  F := FFrames[FrameIdx];
  DS := Max(1, FRollData.PreviewDownScale);
  FirstStrip := Max(0, FrameLeadStrip(F, FRollData.LengthLines));
  LastStrip := Min(FRollData.StripCount - 1, FrameTrailStrip(F, FRollData.LengthLines));
  if LastStrip < FirstStrip then LastStrip := FirstStrip;

  for StripIdx := FirstStrip to LastStrip do
  begin
    LocalLead := F.LeadEdge - Int64(StripIdx) * FRollData.LengthLines;
    LocalTrail := F.TrailEdge - Int64(StripIdx) * FRollData.LengthLines;
    if LocalLead < 0 then LocalLead := 0;
    if LocalTrail > FRollData.LengthLines then LocalTrail := FRollData.LengthLines;
    if LocalTrail <= LocalLead then Continue;

    Path := PreviewFilePath(FRollData, StripIdx);
    if not FileExists(Path) then Continue;
    Bmp := nil;
    try
      Bmp := TBGRABitmap.Create(Path);
      X1 := ClampInt(F.LeftEdge div DS, 0, Bmp.Width - 1);
      X2 := ClampInt((F.RightEdge + DS - 1) div DS, X1 + 1, Bmp.Width);
      Y1 := ClampInt(LocalLead div DS, 0, Bmp.Height - 1);
      Y2 := ClampInt((LocalTrail + DS - 1) div DS, Y1 + 1, Bmp.Height);
      Step := Max(1, Min(X2 - X1, Y2 - Y1) div 180);
      Y := Y1;
      while Y < Y2 do
      begin
        Pix := Bmp.ScanLine[Y];
        Inc(Pix, X1);
        X := X1;
        while X < X2 do
        begin
          Lum := Round(Pix^.red * 0.299 + Pix^.green * 0.587 + Pix^.blue * 0.114);
          Inc(Hist[ClampInt(Lum, 0, 255)]);
          Inc(Count);
          Inc(Pix, Step);
          Inc(X, Step);
        end;
        Inc(Y, Step);
      end;
    except
    end;
    Bmp.Free;
  end;

  if Count < 64 then Exit;
  P2 := Percentile(0.02);
  P50 := Percentile(0.50);
  P98 := Percentile(0.98);
  if P98 <= P2 + 8 then Exit;

  MethodIdx := 0;
  if Assigned(FComboAdjustMethod) then
    MethodIdx := FComboAdjustMethod.ItemIndex;
  LowNorm := P2 / 255.0;
  HighNorm := P98 / 255.0;
  MidNorm := Max(0.05, Min(0.95, P50 / 255.0));
  Span := Max(0.05, HighNorm - LowNorm);

  case MethodIdx of
    1:
      begin
        { Quantum-like sliders: contrast neutral is 64, positive brightness darkens,
          and positive gamma darkens. Dark frames therefore need negative B/G. }
        Scale := 0.82 / Span;
        Contrast := ClampInt(64 + Round((Scale - 1.0) * 62.0), -64, 180);
        Brightness := ClampInt(Round((MidNorm - 0.62) * 180.0), -90, 55);
        Gamma := ClampInt(-Round((Ln(MidNorm) / Ln(0.62) * 100.0 - 100.0) * 1.25), -185, 80);
        if MidNorm < 0.48 then
        begin
          Brightness := Min(Brightness, -18);
          Gamma := Min(Gamma, -35);
        end;
        if HighNorm < 0.70 then
        begin
          Brightness := Min(Brightness, -24);
          Gamma := Min(Gamma, -45);
        end;
      end;
    2, 3:
      begin
        { Curve modes already lift the document tone, so only add gentle fine-tuning. }
        Scale := 0.76 / Span;
        Contrast := ClampInt(Round((Scale - 1.0) * 34.0), -18, 45);
        Brightness := ClampInt(Round((0.56 - MidNorm) * 46.0), -18, 36);
        Gamma := ClampInt(Round(Ln(MidNorm) / Ln(0.64) * 100.0), 100, 160);
        if MidNorm < 0.46 then
        begin
          Brightness := Max(Brightness, 8);
          Gamma := Max(Gamma, 115);
        end;
      end;
    4:
      begin
        { Original curve plus Quantum slider math. Keep the curve, then tune gently
          with Quantum sign conventions. }
        Scale := 0.74 / Span;
        Contrast := ClampInt(64 + Round((Scale - 1.0) * 42.0), -32, 150);
        Brightness := ClampInt(Round((MidNorm - 0.60) * 130.0), -70, 42);
        Gamma := ClampInt(-Round((Ln(MidNorm) / Ln(0.64) * 100.0 - 100.0) * 0.90), -140, 60);
        if MidNorm < 0.46 then
        begin
          Brightness := Min(Brightness, -14);
          Gamma := Min(Gamma, -28);
        end;
      end;
  else
    begin
      { Striplight current sliders: contrast/brightness/gamma neutral is 0/0/100. }
      Scale := 0.86 / Span;
      Contrast := ClampInt(Round((Scale - 1.0) * 58.0), -25, 80);
      Brightness := ClampInt(Round((0.60 - MidNorm) * 76.0), -25, 60);
      Gamma := ClampInt(Round(Ln(MidNorm) / Ln(0.62) * 100.0), 100, 185);
      if MidNorm < 0.48 then
      begin
        Brightness := Max(Brightness, 10);
        Gamma := Max(Gamma, 120);
      end;
      if HighNorm < 0.70 then
      begin
        Brightness := Max(Brightness, 14);
        Gamma := Max(Gamma, 125);
      end;
    end;
  end;
  Result := True;
end;

procedure TMainForm.AutoAdjustSelectedFrames;
var
  I, SelectedCount, ChangedCount, Failed, C, B, G, MethodIdx: Integer;
  NewFrames: TFrameList;
begin
  if not FRollData.Loaded then Exit;
  FFrames := Copy(FStripView.Frames, 0, Length(FStripView.Frames));
  if Length(FFrames) = 0 then Exit;

  SelectedCount := 0;
  for I := 0 to High(FFrames) do
    if FFrames[I].IsSelected then
      Inc(SelectedCount);
  if SelectedCount = 0 then
  begin
    ShowMessage('Select one or more frames first.');
    Exit;
  end;

  NewFrames := Copy(FFrames, 0, Length(FFrames));
  MethodIdx := 0;
  if Assigned(FComboAdjustMethod) then
    MethodIdx := FComboAdjustMethod.ItemIndex;
  ChangedCount := 0;
  Failed := 0;
  for I := 0 to High(FFrames) do
  begin
    if not FFrames[I].IsSelected then Continue;

    if EstimateAutoAdjustmentForFrame(I, C, B, G) then
    begin
      NewFrames[I].CustomContrast := C;
      NewFrames[I].CustomBrightness := B;
      NewFrames[I].CustomGamma := G;
      if MethodIdx = 1 then
      begin
        NewFrames[I].PerFrameContrast := C;
        NewFrames[I].PerFrameBrightness := B;
        NewFrames[I].PerFrameGamma := G;
      end
      else
      begin
        NewFrames[I].PerFrameContrast := -1;
        NewFrames[I].PerFrameBrightness := -1;
        NewFrames[I].PerFrameGamma := -1;
      end;
      Inc(ChangedCount);
    end
    else
      Inc(Failed);
  end;

  if ChangedCount = 0 then
  begin
    ShowMessage('Auto-adjust could not read enough preview pixels for the requested frame(s).');
    Exit;
  end;

  PushFrameUndo;
  FFrames := NewFrames;
  if Assigned(FChkPerFrame) then
  begin
    FChkPerFrame.Checked := True;
    OnPerFrameToggle(FChkPerFrame);
  end;
  FStripView.UpdateFrames(FFrames);
  RefreshFrameColors;
  MarkDirty;
  UpdateSelectedAdjustmentStatus;
  UpdateStatus;
  if Assigned(FPreviewImage) then
    RenderFramePreview;
  if Assigned(FLblExportStatus) then
    FLblExportStatus.Caption := Format('Auto-adjusted %d frame(s). Skipped %d.', [ChangedCount, Failed]);
end;

procedure TMainForm.UpdateTopSnapshot;
var
  SelCount, MarkerCount, Suggested, i, FrameIdx: Integer;
  PreviewText: String;

  function CompactText(const S: String; MaxLen: Integer): String;
  begin
    Result := S;
    if (MaxLen > 12) and (Length(Result) > MaxLen) then
      Result := Copy(Result, 1, 6) + '...' + Copy(Result, Length(Result) - MaxLen + 10, MaxLen - 9);
  end;

begin
  if not Assigned(FLblMetricFrames) then Exit;

  if not FRollData.Loaded then
  begin
    FLblMetricFrames.Caption := 'Frames: -';
    FLblMetricSelection.Caption := 'Selected: -';
    FLblMetricRoll.Caption := 'Roll: no roll loaded';
    FLblMetricPreview.Caption := 'Output: load a roll to preview paths';
    Exit;
  end;

  SelCount := 0;
  MarkerCount := 0;
  Suggested := 0;
  for i := 0 to High(FFrames) do
  begin
    if FFrames[i].IsSelected then Inc(SelCount);
    if FFrames[i].IsMarker then Inc(MarkerCount);
    if FFrames[i].IsSuggested then Inc(Suggested);
  end;

  FLblMetricFrames.Caption := Format('Frames: %d', [Length(FFrames)]);
  FLblMetricSelection.Caption := Format('Selected: %d   Markers: %d   Suggested: %d',
    [SelCount, MarkerCount, Suggested]);
  FLblMetricRoll.Caption := Format('Roll: %s   DPI: %d   Page: %d/%d',
    [FRollData.RollName, FRollData.DPI, FStripView.CurrentPage + 1, Max(1, FStripView.TotalPages)]);

  FrameIdx := GetSingleSelectedFrameIdx;
  if FrameIdx >= 0 then
    PreviewText := ExportNamingPreviewForFrame(FrameIdx, True)
  else
    PreviewText := ProjectFramesFolder;

  FLblMetricPreview.Caption := 'Output: ' + CompactText(PreviewText, 92);
end;

procedure TMainForm.UpdateStatus;
var
  SelCount, Suggested, MarkerCount, i: Integer;
  FrameIdx, S1, S2, S: Integer;
  BoundaryCount, VolumeStart, VolumeEnd, VolumeNo, VolumeFrameCount,
  VolumeFileNo, VolumeSelectedCount: Integer;
  F: TFrameRecord;
  StripNames, Detail, NamingPreview: String;

  function IsFolderBoundary(Idx: Integer): Boolean;
  begin
    Result := (Idx >= 0) and (Idx <= High(FFrames)) and
              (FFrames[Idx].IsMarker or FFrames[Idx].IsSuggested);
  end;

begin
  if not FRollData.Loaded then
  begin
    FStatusBar.Panels[0].Text := 'No roll loaded';
    FStatusBar.Panels[1].Text := '';
    FStatusBar.Panels[2].Text := '';
    FStatusBar.Panels[3].Text := '';
    FStatusBar.Panels[4].Text := '';
    if Assigned(FLblMarkerCount) then
      FLblMarkerCount.Caption := 'Markers in project: 0';
    if Assigned(FGrpMarkers) then
      FGrpMarkers.Caption := 'Folder Markers (0)';
    UpdateTopSnapshot;
    Exit;
  end;

  FStatusBar.Panels[0].Text := Format('Page %d / %d',
    [FStripView.CurrentPage + 1, Max(1, FStripView.TotalPages)]);
  SelCount  := 0;
  Suggested := 0;
  MarkerCount := 0;
  BoundaryCount := 0;
  for i := 0 to High(FFrames) do
  begin
    if FFrames[i].IsSelected  then Inc(SelCount);
    if FFrames[i].IsSuggested then Inc(Suggested);
    if FFrames[i].IsMarker    then Inc(MarkerCount);
    if IsFolderBoundary(i) then Inc(BoundaryCount);
  end;

  FStatusBar.Panels[1].Text := Format('Fr: %d  Mk: %d', [Length(FFrames), MarkerCount]);
  if Assigned(FLblMarkerCount) then
    FLblMarkerCount.Caption := Format('Markers in project: %d', [MarkerCount]);
  if Assigned(FGrpMarkers) then
    FGrpMarkers.Caption := Format('Folder Markers (%d)', [MarkerCount]);

  if Suggested > 0 then
    FStatusBar.Panels[2].Text := Format('Sel: %d  Sug: %d', [SelCount, Suggested])
  else
    FStatusBar.Panels[2].Text := Format('Selected: %d', [SelCount]);

  FStatusBar.Panels[3].Text := Format('Roll: %s  (%d DPI)',
    [FRollData.RollName, FRollData.DPI]);

  { Panel 4: when exactly one frame selected → show frame number, which
    preview files it spans, and the resulting export filename.
    Otherwise show the first preview file on the current page. }
  FrameIdx := GetSingleSelectedFrameIdx;
  if FrameIdx >= 0 then
  begin
    F  := FFrames[FrameIdx];
    S1 := FrameLeadStrip(F, FRollData.LengthLines);
    S2 := FrameTrailStrip(F, FRollData.LengthLines);

    StripNames := '';
    for S := S1 to S2 do
    begin
      if StripNames <> '' then StripNames := StripNames + ', ';
      StripNames := StripNames + ExtractFileName(PreviewFilePath(FRollData, S));
    end;

    NamingPreview := ExportNamingPreviewForFrame(FrameIdx, False);
    Detail := Format('Frame %d | %s | %s', [FrameIdx + 1, StripNames, NamingPreview]);
    if BoundaryCount > 0 then
    begin
      VolumeStart := 0;
      VolumeNo := 0;
      for i := 0 to FrameIdx do
        if IsFolderBoundary(i) then
        begin
          VolumeStart := i;
          Inc(VolumeNo);
        end;
      if VolumeNo = 0 then
        VolumeNo := 1;

      VolumeEnd := High(FFrames);
      for i := FrameIdx + 1 to High(FFrames) do
        if IsFolderBoundary(i) then
        begin
          VolumeEnd := i - 1;
          Break;
        end;

      VolumeFrameCount := Max(1, VolumeEnd - VolumeStart + 1);
      VolumeFileNo := Max(1, FrameIdx - VolumeStart + 1);
      VolumeSelectedCount := 0;
      for i := VolumeStart to VolumeEnd do
        if FFrames[i].IsSelected then
          Inc(VolumeSelectedCount);

      Detail := Detail + Format(' | Folder %d: file %d/%d, selected %d',
        [VolumeNo, VolumeFileNo, VolumeFrameCount, VolumeSelectedCount]);
    end;
    FStatusBar.Panels[4].Text := Detail;
    if Assigned(FLblExportPreview) then
      FLblExportPreview.Caption := 'Export preview: ' + ExportNamingPreviewForFrame(FrameIdx, True);
    HighlightArchiveListLineForFrame(FrameIdx);
  end
  else if SelCount > 1 then
  begin
    FStatusBar.Panels[4].Text := Format('%d frames selected', [SelCount])
  end
  else
  begin
    FStatusBar.Panels[4].Text := Format('Preview: %s',
      [ExtractFileName(PreviewFilePath(FRollData, FStripView.FirstStrip))]);
    if Assigned(FLblExportPreview) then
      FLblExportPreview.Caption := 'Export preview: select a frame';
    if Assigned(FMemoArchiveList) then
      if not FMemoArchiveList.Focused then
        FMemoArchiveList.SelLength := 0;
  end;
  UpdateTopSnapshot;
end;

procedure TMainForm.UpdateFilesTab;
begin
  FEdtRollName.Text  := FRollData.RollName;
  FEdtJobName.Text   := FRollData.RollName;
  FEdtOutputDir.Text := ProjectFramesFolder;
  FSpinQuality.Value := FRollData.JpgQuality;
  LoadExportNamingControlsFromRoll;
end;

end.
