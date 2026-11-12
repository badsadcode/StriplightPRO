unit uTurboJPEG;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Dynlibs, Math, BGRABitmap, BGRABitmapTypes;

function TurboJPEGAvailable: Boolean;
function TurboJPEGStatus: String;
function LoadTurboJPEG(const Path: String; out ABitmap: TBGRABitmap;
  out Err: String): Boolean;
function SaveTurboJPEG(ABitmap: TBGRABitmap; const Path: String; Quality: Integer;
  Grayscale, Progressive: Boolean; out Err: String): Boolean;

implementation

const
  TJPF_BGRA = 8;
  TJPF_GRAY = 6;
  TJSAMP_444 = 0;
  TJSAMP_GRAY = 3;
  TJFLAG_ACCURATEDCT = 4096;
  TJFLAG_PROGRESSIVE = 16384;

type
  TtjInitCompress = function: Pointer; cdecl;
  TtjInitDecompress = function: Pointer; cdecl;
  TtjCompress2 = function(Handle: Pointer; SrcBuf: PByte; Width, Pitch,
    Height, PixelFormat: LongInt; var JpegBuf: PByte; var JpegSize: LongWord;
    JpegSubsamp, JpegQual, Flags: LongInt): LongInt; cdecl;
  TtjDecompressHeader3 = function(Handle: Pointer; JpegBuf: PByte;
    JpegSize: LongWord; var Width, Height, JpegSubsamp,
    JpegColorspace: LongInt): LongInt; cdecl;
  TtjDecompress2 = function(Handle: Pointer; JpegBuf: PByte;
    JpegSize: LongWord; DstBuf: PByte; Width, Pitch, Height,
    PixelFormat, Flags: LongInt): LongInt; cdecl;
  TtjFree = procedure(Buffer: PByte); cdecl;
  TtjDestroy = function(Handle: Pointer): LongInt; cdecl;
  TtjGetErrorStr = function: PAnsiChar; cdecl;

var
  GTurboHandle: TLibHandle = 0;
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

function ProcMissing(const Name: String): Boolean;
begin
  Result := True;
  GLoadError := 'libturbojpeg.dll is missing required function: ' + Name;
end;

function EnsureLoaded: Boolean;
var
  DllPath: String;
begin
  if GLoadAttempted then
    Exit(GTurboHandle <> 0);

  GLoadAttempted := True;
  GLoadError := '';
  DllPath := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) +
    'libturbojpeg.dll';
  if FileExists(DllPath) then
    GTurboHandle := LoadLibrary(DllPath)
  else
    GTurboHandle := LoadLibrary('libturbojpeg.dll');

  if GTurboHandle = 0 then
  begin
    GLoadError := 'libturbojpeg.dll was not found next to Striplight.exe.';
    Exit(False);
  end;

  Pointer(GtjInitCompress) := GetProcedureAddress(GTurboHandle, 'tjInitCompress');
  Pointer(GtjInitDecompress) := GetProcedureAddress(GTurboHandle, 'tjInitDecompress');
  Pointer(GtjCompress2) := GetProcedureAddress(GTurboHandle, 'tjCompress2');
  Pointer(GtjDecompressHeader3) := GetProcedureAddress(GTurboHandle, 'tjDecompressHeader3');
  Pointer(GtjDecompress2) := GetProcedureAddress(GTurboHandle, 'tjDecompress2');
  Pointer(GtjFree) := GetProcedureAddress(GTurboHandle, 'tjFree');
  Pointer(GtjDestroy) := GetProcedureAddress(GTurboHandle, 'tjDestroy');
  Pointer(GtjGetErrorStr) := GetProcedureAddress(GTurboHandle, 'tjGetErrorStr');

  if not Assigned(GtjInitCompress) then Exit(not ProcMissing('tjInitCompress'));
  if not Assigned(GtjInitDecompress) then Exit(not ProcMissing('tjInitDecompress'));
  if not Assigned(GtjCompress2) then Exit(not ProcMissing('tjCompress2'));
  if not Assigned(GtjDecompressHeader3) then Exit(not ProcMissing('tjDecompressHeader3'));
  if not Assigned(GtjDecompress2) then Exit(not ProcMissing('tjDecompress2'));
  if not Assigned(GtjFree) then Exit(not ProcMissing('tjFree'));
  if not Assigned(GtjDestroy) then Exit(not ProcMissing('tjDestroy'));
  if not Assigned(GtjGetErrorStr) then Exit(not ProcMissing('tjGetErrorStr'));

  Result := True;
end;

function TurboJPEGAvailable: Boolean;
begin
  Result := EnsureLoaded;
end;

function TurboJPEGStatus: String;
begin
  if EnsureLoaded then
    Result := 'TurboJPEG DLL ready'
  else
    Result := GLoadError;
end;

function LastTurboError: String;
var
  P: PAnsiChar;
begin
  Result := 'TurboJPEG encode failed.';
  if Assigned(GtjGetErrorStr) then
  begin
    P := GtjGetErrorStr();
    if P <> nil then
      Result := String(AnsiString(P));
  end;
end;

function LoadTurboJPEG(const Path: String; out ABitmap: TBGRABitmap;
  out Err: String): Boolean;
var
  Handle: Pointer;
  Stream: TFileStream;
  JpegData, Pixels: array of Byte;
  Width, Height, Subsamp, Colorspace, Pitch, Y: LongInt;
  JpegSize: LongWord;
begin
  Result := False;
  ABitmap := nil;
  Err := '';
  if not EnsureLoaded then
  begin
    Err := GLoadError;
    Exit;
  end;
  if not FileExists(Path) then
  begin
    Err := 'JPEG file not found: ' + Path;
    Exit;
  end;

  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    if (Stream.Size <= 0) or (Stream.Size > High(LongWord)) then
    begin
      Err := 'JPEG file has unsupported size: ' + Path;
      Exit;
    end;
    JpegSize := LongWord(Stream.Size);
    SetLength(JpegData, JpegSize);
    Stream.ReadBuffer(JpegData[0], JpegSize);
  finally
    Stream.Free;
  end;

  Handle := GtjInitDecompress();
  if Handle = nil then
  begin
    Err := LastTurboError;
    Exit;
  end;

  try
    Width := 0;
    Height := 0;
    Subsamp := 0;
    Colorspace := 0;
    if GtjDecompressHeader3(Handle, @JpegData[0], JpegSize, Width, Height,
      Subsamp, Colorspace) <> 0 then
    begin
      Err := LastTurboError;
      Exit;
    end;
    if (Width <= 0) or (Height <= 0) then
    begin
      Err := 'JPEG has invalid dimensions: ' + Path;
      Exit;
    end;

    ABitmap := TBGRABitmap.Create(Width, Height, BGRA(0, 0, 0, 255));
    Pitch := Width * SizeOf(TBGRAPixel);
    SetLength(Pixels, Pitch * Height);
    if GtjDecompress2(Handle, @JpegData[0], JpegSize, @Pixels[0],
      Width, Pitch, Height, TJPF_BGRA,
      TJFLAG_ACCURATEDCT) <> 0 then
    begin
      Err := LastTurboError;
      FreeAndNil(ABitmap);
      Exit;
    end;
    for Y := 0 to Height - 1 do
      Move(Pixels[Y * Pitch], ABitmap.ScanLine[Y]^, Pitch);
    Result := True;
  finally
    GtjDestroy(Handle);
  end;
end;

procedure BuildGrayBuffer(ABitmap: TBGRABitmap; var Pixels: array of Byte);
var
  X, Y, Offset: Integer;
  P: PBGRAPixel;
begin
  Offset := 0;
  for Y := 0 to ABitmap.Height - 1 do
  begin
    P := ABitmap.ScanLine[Y];
    for X := 0 to ABitmap.Width - 1 do
    begin
      Pixels[Offset] := Byte((LongInt(P^.red) * 77 +
        LongInt(P^.green) * 150 + LongInt(P^.blue) * 29 + 128) shr 8);
      Inc(Offset);
      Inc(P);
    end;
  end;
end;

procedure BuildBGRABuffer(ABitmap: TBGRABitmap; var Pixels: array of Byte;
  Pitch: Integer);
var
  Y: Integer;
begin
  for Y := 0 to ABitmap.Height - 1 do
    Move(ABitmap.ScanLine[Y]^, Pixels[Y * Pitch], Pitch);
end;

function SaveTurboJPEG(ABitmap: TBGRABitmap; const Path: String; Quality: Integer;
  Grayscale, Progressive: Boolean; out Err: String): Boolean;
var
  Handle: Pointer;
  Pixels: array of Byte;
  JpegBuf: PByte;
  JpegSize: LongWord;
  PixelFormat, Subsamp, Pitch, Flags: LongInt;
  Stream: TFileStream;
begin
  Result := False;
  Err := '';
  if not Assigned(ABitmap) then
  begin
    Err := 'No bitmap to export.';
    Exit;
  end;
  if (ABitmap.Width <= 0) or (ABitmap.Height <= 0) then
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
  if Grayscale then
  begin
    Pitch := ABitmap.Width;
    PixelFormat := TJPF_GRAY;
    Subsamp := TJSAMP_GRAY;
    SetLength(Pixels, Pitch * ABitmap.Height);
    BuildGrayBuffer(ABitmap, Pixels);
  end
  else
  begin
    Pitch := ABitmap.Width * 4;
    PixelFormat := TJPF_BGRA;
    Subsamp := TJSAMP_444;
    SetLength(Pixels, Pitch * ABitmap.Height);
    BuildBGRABuffer(ABitmap, Pixels, Pitch);
  end;

  Flags := TJFLAG_ACCURATEDCT;
  if Progressive then
    Flags := Flags or TJFLAG_PROGRESSIVE;

  Handle := GtjInitCompress();
  if Handle = nil then
  begin
    Err := LastTurboError;
    Exit;
  end;

  JpegBuf := nil;
  JpegSize := 0;
  try
    if GtjCompress2(Handle, @Pixels[0], ABitmap.Width, Pitch, ABitmap.Height,
      PixelFormat, JpegBuf, JpegSize, Subsamp, Quality, Flags) <> 0 then
    begin
      Err := LastTurboError;
      Exit;
    end;
    if (JpegBuf = nil) or (JpegSize = 0) then
    begin
      Err := 'TurboJPEG returned an empty JPEG buffer.';
      Exit;
    end;

    Stream := TFileStream.Create(Path, fmCreate);
    try
      Stream.WriteBuffer(JpegBuf^, JpegSize);
    finally
      Stream.Free;
    end;
    Result := True;
  finally
    if JpegBuf <> nil then
      GtjFree(JpegBuf);
    GtjDestroy(Handle);
  end;
end;

finalization
  if GTurboHandle <> 0 then
    UnloadLibrary(GTurboHandle);

end.
