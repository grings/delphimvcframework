program disable_default_logger;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Web.ReqMulti,
  Web.WebReq,
  Web.WebBroker,
  IdContext,
  IdHTTPWebBrokerBridge,
  MVCFramework,
  MVCFramework.Logger,
  MVCFramework.DotEnv,
  MVCFramework.Commons,
  MVCFramework.Serializer.Commons,
  MVCFramework.Signal,
  LoggerPro.Proxy,
  ControllerU in 'ControllerU.pas',
  WebModuleU in 'WebModuleU.pas', LoggerPro {MyWebModule: TWebModule};

{$R *.res}

procedure RunServer(APort: Integer);
var
  LServer: TIdHTTPWebBrokerBridge;
begin
  LServer := TIdHTTPWebBrokerBridge.Create(nil);
  try
    LServer.OnParseAuthentication := TMVCParseAuthentication.OnParseAuthentication;
    LServer.DefaultPort := APort;
    LServer.KeepAlive := dotEnv.Env('dmvc.indy.keep_alive', True);
    LServer.MaxConnections := dotEnv.Env('dmvc.webbroker.max_connections', 0);
    LServer.ListenQueue := dotEnv.Env('dmvc.indy.listen_queue', 500);
    LServer.Active := True;
    LogI('Listening on http://localhost:' + APort.ToString);
    LogI('Application started. Press Ctrl+C to shut down.');
    WaitForTerminationSignal;
    EnterInShutdownState;
    LServer.Active := False;
  finally
    LServer.Free;
  end;
end;

begin
  { Enable ReportMemoryLeaksOnShutdown during debug }
  // ReportMemoryLeaksOnShutdown := True;
  IsMultiThread := True;

  // DMVCFramework Specific Configurations
  //   When MVCSerializeNulls = True empty nullables and nil are serialized as json null.
  //   When MVCSerializeNulls = False empty nullables and nil are not serialized at all.
  MVCSerializeNulls := True;

  // MVCNameCaseDefault defines the name case of property names generated by the serializers.
  //   Possibile values are: ncAsIs, ncUpperCase, ncLowerCase (default), ncCamelCase, ncPascalCase, ncSnakeCase
  MVCNameCaseDefault := TMVCNameCase.ncLowerCase;

  // UseConsoleLogger defines if logs must be emitted to also the console (if available).
  UseConsoleLogger := True;

  // UseLoggerVerbosityLevel defines the lowest level of logs that will be produced.
  UseLoggerVerbosityLevel := TLogLevel.levNormal;

  // ADD THIS
  Log.Disable;

  LogI('** DMVCFramework Server ** build ' + DMVCFRAMEWORK_VERSION);

  try
    if WebRequestHandler <> nil then
      WebRequestHandler.WebModuleClass := WebModuleClass;

    WebRequestHandlerProc.MaxConnections := dotEnv.Env('dmvc.handler.max_connections', 1024);

{$IF CompilerVersion >= 34} //SYDNEY+
    if dotEnv.Env('dmvc.profiler.enabled', false) then
    begin
      Profiler.ProfileLogger := Log;
      Profiler.WarningThreshold := dotEnv.Env('dmvc.profiler.warning_threshold', 1000);
      Profiler.LogsOnlyIfOverThreshold := dotEnv.Env('dmvc.profiler.logs_only_over_threshold', True);
    end;
{$ENDIF}

    RunServer(dotEnv.Env('dmvc.server.port', 8080));
  except
    on E: Exception do
      LogF(E.ClassName + ': ' + E.Message);
  end;
end.
