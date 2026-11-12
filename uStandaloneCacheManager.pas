unit uStandaloneCacheManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Dialogs,
  Math, uTypes, uIDFParser;

type
  TCacheManagerForm = class;

  TCacheWorker = class(TThread)
  private
    FOwner: TCacheManagerForm;
    FPaths: TStringList;
    FIndex: Integer;
    FTotalProjects: Integer;
    FCopied: Integer;
    FSkipped: Integer;
    FMissing: Integer;
    FCurrent: Integer;
    FTotal: Integer;
    FStatus: String;
    function ProjectCacheRoot(const ProjectPath: String): String;
    function ProjectLabel(const ProjectPath: String): String;
    function PreviewSourceFolderPath(const Roll: TRollData): String;
    function PreviewSourcePath(const Roll: TRollData; StripIndex: Integer): String;
    function PreviewCachePath(const Roll: TRollData; StripIndex: Integer): String;
    procedure CopyOneFile(const SourceFile, DestFile: String);
    procedure SyncProgress;
    procedure SyncDone;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TCacheManagerForm; const Paths: TStrings);
    destructor Destroy; override;
  end;

  TCacheManagerForm = class(TForm)
  private
    FMemo: TMemo;
    FList: TListBox;
    FStatus: TLabel;
    FBtnAddPaths: TButton;
    FBtnAddFolder: TButton;
    FBtnRemove: TButton;
    FBtnRefresh: TButton;
    FBtnStart: TButton;
    FBtnStop: TButton;
    FQueue: TStringList;
    FWorker: TCacheWorker;
    function PreviewCacheRoot: String;
    function ProjectNameForIDF(const IDFPath: String): String;
    function ProjectCacheRoot(const IDFPath: String): String;
    function QueueFile: String;
    function FastStatusForProject(const ProjectPath: String): String;
    procedure BuildUI;
    procedure LoadQueue;
    procedure SaveQueue;
    procedure RefreshList;
    procedure AddQueuePath(const Path: String);
    procedure AddQueueFolder(const Folder: String);
    procedure SetRunning(Running: Boolean);
    procedure OnAddPaths(Sender: TObject);
    procedure OnAddFolder(Sender: TObject);
    procedure OnRemove(Sender: TObject);
    procedure OnRefresh(Sender: TObject);
    procedure OnStart(Sender: TObject);
    procedure OnStop(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure WorkerProgress(Index, TotalProjects: Integer; const Status: String);
    procedure WorkerDone(Copied, Skipped, Missing: Integer; Cancelled: Boolean);
  end;

var
  CacheManagerForm: TCacheManagerForm;

implementation

constructor TCacheWorker.Create(AOwner: TCacheManagerForm; const Paths: TStrings);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := AOwner;
  FPaths := TStringList.Create;
  FPaths.Assign(Paths);
  FTotalProjects := FPaths.Count;
  Start;
end;

destructor TCacheWorker.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

function TCacheWorker.ProjectCacheRoot(const ProjectPath: String): String;
begin
  Result := IncludeTrailingPathDelimiter(FOwner.ProjectCacheRoot(ProjectPath));
end;

function TCacheWorker.ProjectLabel(const ProjectPath: String): String;
begin
  Result := ExtractFileName(ProjectPath);
  if Result = '' then
    Result := ProjectPath;
end;

function TCacheWorker.PreviewSourceFolderPath(const Roll: TRollData): String;
var
  SourceBase, SourceFolder: String;
begin
  SourceBase := Roll.PreviewSourceBasePath;
  if SourceBase = '' then SourceBase := Roll.BasePath;
  SourceFolder := Roll.PreviewSourceFolder;
  if SourceFolder = '' then SourceFolder := Roll.PreviewFolder;
  Result := IncludeTrailingPathDelimiter(SourceBase) + SourceFolder;
end;

function TCacheWorker.PreviewSourcePath(const Roll: TRollData; StripIndex: Integer): String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewSourceFolderPath(Roll))
          + Roll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, Roll.StripDigits)
          + '.jpg';
end;

function TCacheWorker.PreviewCachePath(const Roll: TRollData; StripIndex: Integer): String;
begin
  Result := IncludeTrailingPathDelimiter(Roll.PreviewBasePath)
          + Roll.PreviewFolder
          + PathDelim
          + Roll.PreviewPrefix
          + ZeroPadInt(StripIndex + 1, Roll.StripDigits)
          + '.jpg';
end;

procedure TCacheWorker.CopyOneFile(const SourceFile, DestFile: String);
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

procedure TCacheWorker.SyncProgress;
begin
  if Assigned(FOwner) then
    FOwner.WorkerProgress(FIndex, FTotalProjects, FStatus);
end;

procedure TCacheWorker.SyncDone;
begin
  if Assigned(FOwner) then
    FOwner.WorkerDone(FCopied, FSkipped, FMissing, Terminated);
end;

procedure TCacheWorker.Execute;
var
  Roll: TRollData;
  Frames: TFrameList;
  ParseResult: TIDFParseResult;
  ProjectPath, SourcePath, CachePath: String;
  i, ProjectIdx: Integer;
begin
  for ProjectIdx := 0 to FPaths.Count - 1 do
  begin
    if Terminated then Break;
    FIndex := ProjectIdx;
    ProjectPath := FPaths[FIndex];
    Frames := nil;
    ParseResult := ParseIDF(ProjectPath, Roll, Frames);
    if ParseResult <> iprOK then
    begin
      FStatus := Format('Skipping %s: %s', [ExtractFileName(ProjectPath), IDFResultMessage(ParseResult)]);
      Synchronize(@SyncProgress);
      Continue;
    end;

    Roll.PreviewBasePath := ProjectCacheRoot(ProjectPath);
    Roll.PreviewFolder := 'previews';
    Roll.PreviewCacheEnabled := True;
    ForceDirectories(IncludeTrailingPathDelimiter(Roll.PreviewBasePath) + Roll.PreviewFolder);

    FTotal := Max(0, Roll.StripCount);
    FCurrent := 0;
    FStatus := Format('Caching %s   Folder: %s',
      [ProjectLabel(ProjectPath), PreviewSourceFolderPath(Roll)]);
    Synchronize(@SyncProgress);

    for i := 0 to FTotal - 1 do
    begin
      if Terminated then Break;
      FCurrent := i + 1;
      SourcePath := PreviewSourcePath(Roll, i);
      CachePath := PreviewCachePath(Roll, i);

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
          [ProjectLabel(ProjectPath), FCurrent, FTotal, FCopied, FSkipped, FMissing,
           PreviewSourceFolderPath(Roll)]);
        Synchronize(@SyncProgress);
      end;
    end;
  end;

  Synchronize(@SyncDone);
end;

constructor TCacheManagerForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Caption := 'Striplight Cache Manager';
  Position := poScreenCenter;
  Width := 900;
  Height := 620;
  FQueue := TStringList.Create;
  BuildUI;
  LoadQueue;
  RefreshList;
end;

destructor TCacheManagerForm.Destroy;
begin
  SaveQueue;
  if Assigned(FWorker) then
  begin
    FWorker.FOwner := nil;
    FWorker.Terminate;
  end;
  FQueue.Free;
  inherited Destroy;
end;

function TCacheManagerForm.PreviewCacheRoot: String;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
            'Striplight_preview_cache';
end;

function TCacheManagerForm.ProjectNameForIDF(const IDFPath: String): String;
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

function TCacheManagerForm.ProjectCacheRoot(const IDFPath: String): String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewCacheRoot) + ProjectNameForIDF(IDFPath);
end;

function TCacheManagerForm.QueueFile: String;
begin
  Result := IncludeTrailingPathDelimiter(PreviewCacheRoot) + 'cache_queue.txt';
end;

function TCacheManagerForm.FastStatusForProject(const ProjectPath: String): String;
begin
  if DirectoryExists(IncludeTrailingPathDelimiter(ProjectCacheRoot(ProjectPath)) + 'previews') then
    Result := '[cache found] '
  else
    Result := '[not cached] ';
end;

procedure TCacheManagerForm.BuildUI;
var
  TopPanel, ActionPanel, BottomPanel, QueuePanel: TPanel;

  function MakeButton(const Text: String; TopPos: Integer; Handler: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := ActionPanel;
    Result.Caption := Text;
    Result.Left := 8;
    Result.Top := TopPos;
    Result.Width := 150;
    Result.Height := 28;
    Result.OnClick := Handler;
  end;

begin
  TopPanel := TPanel.Create(Self);
  TopPanel.Parent := Self;
  TopPanel.Align := alTop;
  TopPanel.Height := 188;
  TopPanel.BevelOuter := bvNone;
  TopPanel.BorderSpacing.Around := 8;

  ActionPanel := TPanel.Create(Self);
  ActionPanel.Parent := TopPanel;
  ActionPanel.Align := alRight;
  ActionPanel.Width := 170;
  ActionPanel.BevelOuter := bvNone;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := TopPanel;
  FMemo.Align := alClient;
  FMemo.BorderSpacing.Right := 8;
  FMemo.ScrollBars := ssBoth;
  FMemo.WordWrap := False;

  FBtnAddPaths := MakeButton('Add Paths', 0, @OnAddPaths);
  FBtnAddFolder := MakeButton('Add Folder...', 36, @OnAddFolder);
  FBtnRemove := MakeButton('Remove Selected', 76, @OnRemove);
  FBtnRefresh := MakeButton('Refresh List', 112, @OnRefresh);
  FBtnStart := MakeButton('Start Queue', 150, @OnStart);
  FBtnStart.Width := 72;
  FBtnStop := TButton.Create(Self);
  FBtnStop.Parent := ActionPanel;
  FBtnStop.Caption := 'Stop';
  FBtnStop.Left := 86;
  FBtnStop.Top := 150;
  FBtnStop.Width := 72;
  FBtnStop.Height := 28;
  FBtnStop.Enabled := False;
  FBtnStop.OnClick := @OnStop;

  BottomPanel := TPanel.Create(Self);
  BottomPanel.Parent := Self;
  BottomPanel.Align := alBottom;
  BottomPanel.Height := 42;
  BottomPanel.BevelOuter := bvNone;
  BottomPanel.BorderSpacing.Around := 8;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := BottomPanel;
  FStatus.Align := alClient;
  FStatus.Caption := 'Ready.';

  QueuePanel := TPanel.Create(Self);
  QueuePanel.Parent := Self;
  QueuePanel.Align := alClient;
  QueuePanel.BevelOuter := bvNone;
  QueuePanel.BorderSpacing.Left := 8;
  QueuePanel.BorderSpacing.Right := 8;

  FList := TListBox.Create(Self);
  FList.Parent := QueuePanel;
  FList.Align := alClient;
  FList.MultiSelect := True;
  FList.ScrollWidth := 1200;
end;

procedure TCacheManagerForm.LoadQueue;
begin
  if FileExists(QueueFile) then
    FQueue.LoadFromFile(QueueFile);
end;

procedure TCacheManagerForm.SaveQueue;
begin
  ForceDirectories(PreviewCacheRoot);
  FQueue.SaveToFile(QueueFile);
end;

procedure TCacheManagerForm.RefreshList;
var
  i: Integer;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i := 0 to FQueue.Count - 1 do
      FList.Items.Add(FastStatusForProject(FQueue[i]) + FQueue[i]);
  finally
    FList.Items.EndUpdate;
  end;
  FStatus.Caption := Format('Projects in queue: %d', [FQueue.Count]);
end;

procedure TCacheManagerForm.AddQueuePath(const Path: String);
var
  P, Ext: String;
begin
  P := Trim(Path);
  if (Length(P) >= 2) and (P[1] = '"') and (P[Length(P)] = '"') then
    P := Copy(P, 2, Length(P) - 2);
  if P = '' then Exit;

  if DirectoryExists(P) then
  begin
    AddQueueFolder(P);
    Exit;
  end;

  Ext := LowerCase(ExtractFileExt(P));
  if ((Ext = '.idf') or (Ext = '.xml')) and FileExists(P) then
    if FQueue.IndexOf(P) < 0 then
      FQueue.Add(P);
end;

procedure TCacheManagerForm.AddQueueFolder(const Folder: String);
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
          AddQueueFolder(Path)
        else
        begin
          Ext := LowerCase(ExtractFileExt(Path));
          if ((Ext = '.idf') or (Ext = '.xml')) and (FQueue.IndexOf(Path) < 0) then
            FQueue.Add(Path);
        end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
end;

procedure TCacheManagerForm.SetRunning(Running: Boolean);
begin
  FBtnAddPaths.Enabled := not Running;
  FBtnAddFolder.Enabled := not Running;
  FBtnRemove.Enabled := not Running;
  FBtnRefresh.Enabled := not Running;
  FBtnStart.Enabled := not Running;
  FBtnStop.Enabled := Running;
end;

procedure TCacheManagerForm.OnAddPaths(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to FMemo.Lines.Count - 1 do
    AddQueuePath(FMemo.Lines[i]);
  SaveQueue;
  RefreshList;
end;

procedure TCacheManagerForm.OnAddFolder(Sender: TObject);
var
  Folder: String;
begin
  Folder := '';
  if SelectDirectory('Select folder to scan for IDF/XML projects', '', Folder) then
  begin
    AddQueueFolder(Folder);
    SaveQueue;
    RefreshList;
  end;
end;

procedure TCacheManagerForm.OnRemove(Sender: TObject);
var
  i: Integer;
begin
  for i := FList.Items.Count - 1 downto 0 do
    if FList.Selected[i] then
      FQueue.Delete(i);
  SaveQueue;
  RefreshList;
end;

procedure TCacheManagerForm.OnRefresh(Sender: TObject);
begin
  RefreshList;
end;

procedure TCacheManagerForm.OnStart(Sender: TObject);
begin
  if FQueue.Count = 0 then
  begin
    ShowMessage('Add at least one project path first.');
    Exit;
  end;
  if Assigned(FWorker) then Exit;
  SetRunning(True);
  FWorker := TCacheWorker.Create(Self, FQueue);
end;

procedure TCacheManagerForm.OnStop(Sender: TObject);
begin
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    FStatus.Caption := 'Stopping after current file...';
  end;
end;

procedure TCacheManagerForm.WorkerProgress(Index, TotalProjects: Integer; const Status: String);
begin
  if (Index >= 0) and (Index < FList.Items.Count) then
    FList.ItemIndex := Index;
  FStatus.Caption := Format('Project %d / %d   %s', [Index + 1, TotalProjects, Status]);
end;

procedure TCacheManagerForm.WorkerDone(Copied, Skipped, Missing: Integer; Cancelled: Boolean);
begin
  FWorker := nil;
  SetRunning(False);
  RefreshList;
  if Cancelled then
    FStatus.Caption := Format('Stopped. Copied: %d   Already cached: %d   Missing: %d',
      [Copied, Skipped, Missing])
  else
    FStatus.Caption := Format('Complete. Copied: %d   Already cached: %d   Missing: %d',
      [Copied, Skipped, Missing]);
end;

end.
