unit uToneBitmap;

{ Applies a Striplight tone adjustment (see uToneAdjust) to a TBGRABitmap.

  The strip view, the frame preview window and the BGRA export path all call
  this one procedure, so the three always use the same math. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, BGRABitmap, BGRABitmapTypes, uToneAdjust;

{ Adjusts ABitmap in place. The caller decides whether an adjustment is
  wanted at all; this procedure always applies what it is given.
  InvertedPolarity: the image is still a negative at this point. }
procedure ApplyToneToBitmap(ABitmap: TBGRABitmap; Method, Flags, Contrast,
  Brightness, Gamma, Strength: Integer; InvertedPolarity: Boolean);

implementation

procedure ApplyLUTToBitmap(ABitmap: TBGRABitmap; const LUT: TToneLUT);
var
  X, Y: Integer;
  P: PBGRAPixel;
begin
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

{ The adaptive methods work on brightness. Gray pixels simply take the new
  value; coloured pixels keep their colour and are scaled to the new
  brightness. }
procedure ApplyAdaptiveToBitmap(ABitmap: TBGRABitmap; Method, Strength: Integer;
  InvertedPolarity: Boolean);
var
  W, H, X, Y, OldL, NewL: Integer;
  Gray, G: PByte;
  P: PBGRAPixel;

  function Scale(Channel: Integer): Byte;
  var
    V: Integer;
  begin
    V := (Channel * NewL + OldL div 2) div OldL;
    if V > 255 then V := 255;
    Result := V;
  end;

begin
  W := ABitmap.Width;
  H := ABitmap.Height;
  if (W <= 0) or (H <= 0) then Exit;
  GetMem(Gray, PtrUInt(W) * PtrUInt(H));
  try
    for Y := 0 to H - 1 do
    begin
      P := ABitmap.ScanLine[Y];
      G := Gray + PtrInt(Y) * W;
      for X := 0 to W - 1 do
      begin
        G^ := Byte((LongInt(P^.red) * 77 + LongInt(P^.green) * 150 +
                    LongInt(P^.blue) * 29 + 128) shr 8);
        Inc(G);
        Inc(P);
      end;
    end;

    ApplyAdaptiveGray(Gray, W, H, W, Method, Strength, InvertedPolarity);

    for Y := 0 to H - 1 do
    begin
      P := ABitmap.ScanLine[Y];
      G := Gray + PtrInt(Y) * W;
      for X := 0 to W - 1 do
      begin
        NewL := G^;
        if (P^.red = P^.green) and (P^.green = P^.blue) then
        begin
          P^.red := NewL;
          P^.green := NewL;
          P^.blue := NewL;
        end
        else
        begin
          OldL := (LongInt(P^.red) * 77 + LongInt(P^.green) * 150 +
                   LongInt(P^.blue) * 29 + 128) shr 8;
          if OldL <= 0 then
          begin
            P^.red := NewL;
            P^.green := NewL;
            P^.blue := NewL;
          end
          else
          begin
            P^.red := Scale(P^.red);
            P^.green := Scale(P^.green);
            P^.blue := Scale(P^.blue);
          end;
        end;
        Inc(G);
        Inc(P);
      end;
    end;
  finally
    FreeMem(Gray);
  end;
end;

procedure ApplyToneToBitmap(ABitmap: TBGRABitmap; Method, Flags, Contrast,
  Brightness, Gamma, Strength: Integer; InvertedPolarity: Boolean);
var
  LUT: TToneLUT;
begin
  if ABitmap = nil then Exit;
  if ToneMethodIsAdaptive(Method) then
  begin
    ApplyAdaptiveToBitmap(ABitmap, Method, Strength, InvertedPolarity);
    { Sliders and options of the adaptive methods use the Striplight ranges
      and come after the adaptive step. }
    if ToneIsNoOp(TONE_STRIPLIGHT, Flags, Contrast, Brightness, Gamma, 0) then
      Exit;
    BuildToneLUT(TONE_STRIPLIGHT, Flags, Contrast, Brightness, Gamma, LUT);
  end
  else
    BuildToneLUT(Method, Flags, Contrast, Brightness, Gamma, LUT);
  ApplyLUTToBitmap(ABitmap, LUT);
end;

end.
