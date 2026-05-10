program DataURLUploadServer;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Signal,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.Middleware.StaticFiles,
  DataURLTypeU in 'DataURLTypeU.pas',
  UploadDTOU in 'UploadDTOU.pas',
  UploadControllerU in 'UploadControllerU.pas';

{$R *.res}

const
  PORT = 8080;

procedure RunServer;
var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
begin
  WriteLn('** DMVCFramework Data URL Upload Sample **');
  WriteLn;

  LEngine := TMVCEngine.Create(
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.APPLICATION_JSON;
      // Data URLs balloon by ~33% over the raw bytes; raise the cap accordingly.
      Config[TMVCConfigKey.MaxRequestSize] := IntToStr(20 * 1024 * 1024);
    end);
  try
    LEngine.AddController(TUploadController);
    LEngine.AddMiddleware(TMVCStaticFilesMiddleware.Create('/static', 'www'));

    // Plug TDataURL into JSON (de)serialization.
    LEngine.Serializers.Items[TMVCMediaType.APPLICATION_JSON]
      .RegisterTypeSerializer(TypeInfo(TDataURL), TDataURLSerializer.Create);

    LServer := TMVCServerFactory.CreateIndyDirect(LEngine);
    LServer.Listen(PORT);
    try
      WriteLn('Server started on port ', PORT, ' (Indy Direct)');
      WriteLn;
      WriteLn('Open your browser at:');
      WriteLn;
      WriteLn('  ==> http://localhost:', PORT, '/static/index.html');
      WriteLn;
      WriteLn('Drop a file on the page to POST it as a JSON-embedded data URL.');
      WriteLn('The server decodes it via TDataURL custom type serializer and');
      WriteLn('saves the bytes under the "uploaded" folder next to the executable.');
      WriteLn;
      WriteLn('Press Ctrl+C to stop.');
      WaitForTerminationSignal;
      WriteLn('Shutting down...');
    finally
      LServer.Stop;
      LServer := nil;
    end;
  finally
    LEngine.Free;
  end;
end;

begin
  ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;
  try
    RunServer;
  except
    on E: Exception do
      WriteLn(E.ClassName, ': ', E.Message);
  end;
end.
