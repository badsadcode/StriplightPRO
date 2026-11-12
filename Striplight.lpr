program Striplight;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,   // LCL widgetset
  Forms,
  uTypes,
  uIDFParser,
  uStripView,
  uQPF,
  uFrameDetect,
  uMainForm;

{$R *.res}
{$R StriplightIcon.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled         := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.

