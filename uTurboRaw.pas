unit uTurboRaw;

{ TurboJPEG access on plain memory buffers, without BGRABitmap.

  Used by the fast grayscale export path: strips are decoded straight to
  8-bit gray (a quarter of the memory of BGRA) and frames are compressed to a
  memory buffer, so several export workers can compress at the same time and
  only the final file write has to take turns.

  Each call creates its own TurboJPEG handle, so the functions are safe to
  call from several threads at once. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Dynlibs, Math, ctypes;

const
  TURBO_PF_GRAY = 6;   // TJPF_GRAY
  TURBO_PF_BGRA = 8;   // TJPF_BGRA

function TurboRawAvailable: Boolean;
function TurboRawStatus: String;

{ Decodes a grayscale JPEG file to an 8-bit buffer (Width bytes per row,
  top row first). The caller frees Pixels with FreeMem.
  When the file is a colour JPEG nothing is decoded: the function returns
  False with IsGray = False, and the caller should use the BGRA path. }
function TurboLoadGrayFile(const Path: String; out Width, Height: Integer;
  out Pixels: PByte; out IsGray: Boolean; out Err: String): Boolean;

{ Compresses a pixel buffer to JPEG in memory.
  TURBO_PF_GRAY: one byte per pixel, written as a grayscale JPEG.
  TURBO_PF_BGRA: four bytes per pixel, written as 4:4:4 colour. }
function TurboEncode(Pixels: PByte; Width, Height, Pitch, PixelFormat,
  Quality: Integer; Progressive: Boolean; out Jpeg: TBytes;
  out Err: String): Boolean;

{ Writes a memory buffer to a file in one go. }
function WriteBytesToFile(const Path: String; const Data: TBytes;
  out Err: String): Boolean;

implementation

const
  TJSAMP_444 = 0;
  TJSAMP_GRAY = 3;
  TJCS_GRAY = 2;
  TJFLAG_ACCURATEDCT = 4096;
  TJFLAG_PROGRESSIVE = 16384;
  {$IFDEF MSWINDOWS}
  TURBO_LIB_NAME = 'libturbojpeg.dll';
  {$ELSE}
  TURBO_LIB_NAME = 'libturbojpeg.so.0';
  {$ENDIF}

type
  { C "unsigned long": 32 bits on Windows, 64 bits on 64-bit Linux. }
  TTurboSize = culong;

  TtjInitCompress = function: Pointer; cdecl;
  TtjInitDecompress = function: Pointer; cdecl;
  TtjCompress2 = function(Handle: Pointer; SrcBuf: PByte; Width, Pitch,
    Height, PixelFormat: LongInt; var JpegBuf: PByte; var JpegSize: TTurboSize;
    JpegSubsamp, JpegQual, Flags: LongInt): LongInt; cdecl;
  TtjDecompressHeader3 = function(Handle: Pointer; JpegBuf: PByte;
    JpegSize: TTurboSize; var Width, Height, JpegSubsamp,
    JpegColorspace: LongInt): LongInt; cdecl;
  TtjDecompress2 = function(Handle: Pointer; JpegBuf: PByte;
    JpegSize: TTurboSize; DstBuf: PByte; Width, Pitch, Height,
    PixelFormat, Flags: LongInt): LongInt; cdecl;
  TtjFree = procedure(Buffer: PByte); cdecl;
  TtjDestroy = function(Handle: Pointer): LongInt; cdecl;
  TtjGetErrorStr = function: PAnsiChar; cdecl;

var
  GLock: TRTLCriticalSection;
  GHandle: TLibHandle = 0;
  GLoadAttempted: Boolean = False;
  GLoadError: String = '';
  GtjInitCompress: TtjInitCompress = nil;
  GtjInitDecompress: TtjInitDecompress = nil;
  GtjCompress2: TtjCompress2 = nil;
  GtjDecompressHeader3: TtjDecompressHeader3 = nil;
  GtjDecompress2: TtjDecompress2 = nil;
  GtjFree: TtjFree = nil;
  GtjDestroy: TtjDestroy = nil;
  GtjGetErrorStr: TtjGetErrorStr = nil;

function LoadProcs: Boolean;

  function Need(var Proc: Pointer; const Name: String): Boolean;
  begin
    Proc := GetProcedureAddress(GHandle, Name);
    Result := Proc <> nil;
    if not Result then
      GLoadError := TURBO_LIB_NAME + ' is missing required function: ' + Name;
  end;

begin
  Result :=
    Need(Pointer(GtjInitCompress), 'tjInitCompress') and
    Need(Pointer(GtjInitDecompress), 'tjInitDecompress') and
    Need(Pointer(GtjCompress2), 'tjCompress2') and
    Need(Pointer(GtjDecompressHeader3), 'tjDecompressHeader3') and
    Need(Pointer(GtjDecompress2), 'tjDecompress2') and
    Need(Pointer(GtjFree), 'tjFree') and
    Need(Pointer(GtjDestroy), 'tjDestroy') and
    Need(Pointer(GtjGetErrorStr), 'tjGetErrorStr');
end;

function EnsureLoaded: Boolean;
var
  LibPath: String;
begin
  EnterCriticalSection(GLock);
  try
    if GLoadAttempted then
      Exit(GHandle <> 0);
    GLoadAttempted := True;
    GLoadError := '';
    LibPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
      TURBO_LIB_NAME;
    if FileExists(LibPath) then
      GHandle := LoadLibrary(LibPath)
    else
      GHandle := LoadLibrary(TURBO_LIB_NAME);
    if GHandle = 0 then
    begin
      GLoadError := TURBO_LIB_NAME + ' was not found next to the program.';
      Exit(False);
    end;
    if not LoadProcs then
    begin
      UnloadLibrary(GHandle);
      GHandle := 0;
      Exit(False);
    end;
    Result := True;
  finally
    LeaveCriticalSection(GLock);
  end;
end;

function TurboRawAvailable: Boolean;
begin
  Result := EnsureLoaded;
end;

function TurboRawStatus: String;
begin
  if EnsureLoaded then
    Result := 'TurboJPEG ready'
  else
    Result := GLoadError;
end;

function LastTurboError(const Fallback: String): String;
var
  P: PAnsiChar;
begin
  Result := Fallback;
  if Assigned(GtjGetErrorStr) then
  begin
    P := GtjGetErrorStr();
    if (P <> nil) and (P^ <> #0) then
      Result := String(AnsiString(P));
  end;
end;

function TurboLoadGrayFile(const Path: String; out Width, Height: Integer;
  out Pixels: PByte; out IsGray: Boolean; out Err: String): Boolean;
var
  Handle: Pointer;
  Stream: TFileStream;
  JpegData: TBytes;
  W, H, Subsamp, Colorspace: LongInt;
  JpegSize: TTurboSize;
begin
  Result := False;
  Width := 0;
  Height := 0;
  Pixels := nil;
  IsGray := True;
  Err := '';
  if not EnsureLoaded then
  begin
    Err := GLoadError;
    Exit;
  end;

  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if (Stream.Size <= 0) or (Stream.Size > High(LongInt)) then
      begin
        Err := 'JPEG file has unsupported size: ' + Path;
        Exit;
      end;
      JpegSize := TTurboSize(Stream.Size);
      SetLength(JpegData, JpegSize);
      Stream.ReadBuffer(JpegData[0], JpegSize);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      Err := E.Message;
      Exit;
    end;
  end;

  Handle := GtjInitDecompress();
  if Handle = nil then
  begin
    Err := LastTurboError('TurboJPEG decode failed.');
    Exit;
  end;
  try
    W := 0;
    H := 0;
    Subsamp := 0;
    Colorspace := 0;
    if GtjDecompressHeader3(Handle, @JpegData[0], JpegSize, W, H, Subsamp,
      Colorspace) <> 0 then
    begin
      Err := LastTurboError('TurboJPEG decode failed.');
      Exit;
    end;
    if (W <= 0) or (H <= 0) then
    begin
      Err := 'JPEG has invalid dimensions: ' + Path;
      Exit;
    end;
    if Colorspace <> TJCS_GRAY then
    begin
      IsGray := False;
      Err := 'JPEG is not grayscale: ' + Path;
      Exit;
    end;

    try
      GetMem(Pixels, PtrUInt(W) * PtrUInt(H));
    except
      on E: Exception do
      begin
        Pixels := nil;
        Err := 'Out of memory decoding ' + Path;
        Exit;
      end;
    end;
    if GtjDecompress2(Handle, @JpegData[0], JpegSize, Pixels, W, W, H,
      TURBO_PF_GRAY, TJFLAG_ACCURATEDCT) <> 0 then
    begin
      Err := LastTurboError('TurboJPEG decode failed.');
      FreeMem(Pixels);
      Pixels := nil;
      Exit;
    end;
    Width := W;
    Height := H;
    Result := True;
  finally
    GtjDestroy(Handle);
  end;
end;

function TurboEncode(Pixels: PByte; Width, Height, Pitch, PixelFormat,
  Quality: Integer; Progressive: Boolean; out Jpeg: TBytes;
  out Err: String): Boolean;
var
  Handle: Pointer;
  JpegBuf: PByte;
  JpegSize: TTurboSize;
  Subsamp, Flags: LongInt;
begin
  Result := False;
  Err := '';
  Jpeg := nil;
  if (Pixels = nil) or (Width <= 0) or (Height <= 0) then
  begin
    Err := 'Bitmap has invalid dimensions.';
    Exit;
  end;
  if not EnsureLoaded then
  begin
    Err := GLoadError;
    Exit;
  end;

  Quality := Max(1, Min(100, Quality));
  if PixelFormat = TURBO_PF_GRAY then
    Subsamp := TJSAMP_GRAY
  else
    Subsamp := TJSAMP_444;
  Flags := TJFLAG_ACCURATEDCT;
  if Progressive then
    Flags := Flags or TJFLAG_PROGRESSIVE;

  Handle := GtjInitCompress();
  if Handle = nil then
  begin
    Err := LastTurboError('TurboJPEG encode failed.');
    Exit;
  end;
  JpegBuf := nil;
  JpegSize := 0;
  try
    if GtjCompress2(Handle, Pixels, Width, Pitch, Height, PixelFormat,
      JpegBuf, JpegSize, Subsamp, Quality, Flags) <> 0 then
    begin
      Err := LastTurboError('TurboJPEG encode failed.');
      Exit;
    end;
    if (JpegBuf = nil) or (JpegSize = 0) then
    begin
      Err := 'TurboJPEG returned an empty JPEG buffer.';
      Exit;
    end;
    SetLength(Jpeg, JpegSize);
    Move(JpegBuf^, Jpeg[0], JpegSize);
    Result := True;
  finally
    if JpegBuf <> nil then
      GtjFree(JpegBuf);
    GtjDestroy(Handle);
  end;
end;

function WriteBytesToFile(const Path: String; const Data: TBytes;
  out Err: String): Boolean;
var
  Stream: TFileStream;
begin
  Result := False;
  Err := '';
  if Length(Data) = 0 then
  begin
    Err := 'Nothing to write.';
    Exit;
  end;
  try
    Stream := TFileStream.Create(Path, fmCreate);
    try
      Stream.WriteBuffer(Data[0], Length(Data));
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

initialization
  InitCriticalSection(GLock);

finalization
  if GHandle <> 0 then
    UnloadLibrary(GHandle);
  DoneCriticalSection(GLock);

end.
