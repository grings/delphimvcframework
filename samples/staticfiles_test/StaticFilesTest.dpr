program StaticFilesTest;

// Empirical verification for the minimal-API HTTPFilter helpers
// (StaticFiles, Compression, ETag, IPBlock, RateLimit, RequestLog,
// CORSFilter). Each scenario spins a fresh engine on its own port so
// filter state cannot bleed across scenarios.
//
// Exit code: 0 = all pass, 1 = at least one failure.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  System.SyncObjs,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.MinimalAPI,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.RESTClient,
  MVCFramework.RESTClient.Intf,
  MVCFramework.Logger;

const
  PORT_BASE             = 8765;
  WWW_DIR               = 'www';
  TEST_HTML             = '<h1>StaticFiles works</h1>';
  INDEX_HTML            = '<h1>Default index</h1>';
  JSON_BODY             = '{"k":"v"}';
  COMPRESSION_THRESHOLD = 256;

var
  GFailures: Integer = 0;

procedure Pass(const AName: string);
begin
  WriteLn('[PASS] ', AName);
end;

procedure Fail(const AName, ADetail: string);
begin
  WriteLn('[FAIL] ', AName, ' -- ', ADetail);
  Inc(GFailures);
end;

procedure AssertStatusBody(const AResp: IMVCRESTResponse;
  AExpectedStatus: Integer; const AExpectedBody, AName: string);
begin
  if (AResp.StatusCode = AExpectedStatus) and (AResp.Content = AExpectedBody) then
    Pass(AName)
  else
    Fail(AName, Format('status=%d body=[%s]', [AResp.StatusCode, AResp.Content]));
end;

procedure AssertStatus(const AResp: IMVCRESTResponse;
  AExpectedStatus: Integer; const AName: string);
begin
  if AResp.StatusCode = AExpectedStatus then
    Pass(AName)
  else
    Fail(AName, Format('expected status=%d got=%d body=[%s]',
      [AExpectedStatus, AResp.StatusCode, AResp.Content]));
end;

// Repeating ASCII compresses well — easy to tell from the original bytes.
function MakeBigContent: string;
var
  i: Integer;
  lSB: TStringBuilder;
begin
  lSB := TStringBuilder.Create;
  try
    for i := 1 to 200 do
      lSB.Append('Lorem ipsum dolor sit amet, consectetur adipiscing elit. ');
    Result := lSB.ToString;
  finally
    lSB.Free;
  end;
end;

procedure SetupFixtures;
var
  lDir: string;
begin
  lDir := TPath.Combine(GetCurrentDir, WWW_DIR);
  if not TDirectory.Exists(lDir) then
    TDirectory.CreateDirectory(lDir);
  TFile.WriteAllText(TPath.Combine(lDir, 'test.html'), TEST_HTML);
  TFile.WriteAllText(TPath.Combine(lDir, 'index.html'), INDEX_HTML);
  TFile.WriteAllText(TPath.Combine(lDir, 'data.json'), JSON_BODY);
  TFile.WriteAllText(TPath.Combine(lDir, 'big.html'), MakeBigContent);
end;

// Runs an isolated scenario: fresh engine + Indy server on APort, runs
// AConfigure to register filters/routes, then ARunTests with an
// IMVCRESTClient pointing at the server. Tears everything down.
procedure WithEngine(APort: Integer;
  const AConfigure: TProc<TMVCEngine>;
  const ARunTests: TProc<IMVCRESTClient>);
var
  lEngine: TMVCEngine;
  lServer: IMVCServer;
  lClient: IMVCRESTClient;
begin
  lEngine := TMVCEngine.Create(
    procedure (AConfig: TMVCConfig)
    begin
      AConfig[TMVCConfigKey.DefaultContentType] := TMVCMediaType.TEXT_HTML;
      AConfig[TMVCConfigKey.AllowUnhandledAction] := 'false';
      AConfig[TMVCConfigKey.LoadSystemControllers] := 'false';
      AConfig[TMVCConfigKey.ExposeServerSignature] := 'false';
    end);
  try
    AConfigure(lEngine);
    lServer := TMVCServerFactory.CreateIndyDirect(lEngine);
    lServer.Listen(APort);
    try
      Sleep(200); // let Indy bind
      lClient := TMVCRESTClient.New.BaseURL('http://localhost:' + APort.ToString);
      ARunTests(lClient);
    finally
      lServer.Stop;
      lServer := nil;
    end;
  finally
    lEngine.Free;
  end;
end;

// -- scenario 1: StaticFiles + Compression + ETag ---------------------------

procedure ConfigStatic(AEngine: TMVCEngine);
begin
  AEngine.UseHTTPFilter(ETag());
  AEngine.UseHTTPFilter(Compression(COMPRESSION_THRESHOLD));
  AEngine.UseHTTPFilter(StaticFiles('/static', WWW_DIR));
  AEngine.Root.AsWeb.MapGet('/hello',
    function: IMVCResponse
    begin
      Result := Ok('hi');
    end);
end;

procedure TestStatic(AClient: IMVCRESTClient);
var
  lResp: IMVCRESTResponse;
  lEtag: string;
begin
  lResp := AClient.Get('/static/test.html');
  AssertStatusBody(lResp, 200, TEST_HTML, 'GET /static/test.html');

  lResp := AClient.Get('/static/');
  AssertStatusBody(lResp, 200, INDEX_HTML, 'GET /static/  -> index.html');

  lResp := AClient.Get('/static');
  AssertStatusBody(lResp, 200, INDEX_HTML, 'GET /static   -> index.html');

  lResp := AClient.Get('/static/../etc/passwd');
  AssertStatus(lResp, 403, 'GET /static/../etc/passwd -> 403');

  lResp := AClient.Get('/static/missing.html');
  AssertStatus(lResp, 404, 'GET /static/missing.html -> 404');

  lResp := AClient.Get('/hello');
  AssertStatus(lResp, 200, 'GET /hello -> handler runs');

  lResp := AClient.Get('/static/data.json');
  if (lResp.StatusCode = 200) and lResp.ContentType.ToLower.Contains('application/json') then
    Pass('GET /static/data.json -> 200 application/json')
  else
    Fail('GET /static/data.json',
      Format('status=%d ct=%s', [lResp.StatusCode, lResp.ContentType]));

  // Compression
  lResp := AClient.AcceptEncoding('gzip').Get('/static/big.html');
  if (lResp.StatusCode = 200)
     and SameText(lResp.HeaderValue('Content-Encoding'), 'gzip')
     and (lResp.Content = MakeBigContent) then
    Pass('GET /static/big.html (Accept gzip) -> gzip + body matches')
  else
    Fail('GET /static/big.html (Accept gzip)',
      Format('status=%d ce=%s len=%d',
        [lResp.StatusCode, lResp.HeaderValue('Content-Encoding'), Length(lResp.Content)]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.AcceptEncoding('deflate').Get('/static/big.html');
  if (lResp.StatusCode = 200)
     and SameText(lResp.HeaderValue('Content-Encoding'), 'deflate')
     and (lResp.Content = MakeBigContent) then
    Pass('GET /static/big.html (Accept deflate) -> deflate + body matches')
  else
    Fail('GET /static/big.html (Accept deflate)',
      Format('status=%d ce=%s len=%d',
        [lResp.StatusCode, lResp.HeaderValue('Content-Encoding'), Length(lResp.Content)]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.AcceptEncoding('').Get('/static/big.html');
  if (lResp.StatusCode = 200)
     and (lResp.HeaderValue('Content-Encoding') = '')
     and (lResp.Content = MakeBigContent) then
    Pass('GET /static/big.html (no Accept-Encoding) -> uncompressed')
  else
    Fail('GET /static/big.html (no Accept-Encoding)',
      Format('status=%d ce=%s',
        [lResp.StatusCode, lResp.HeaderValue('Content-Encoding')]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.AcceptEncoding('gzip').Get('/static/test.html');
  if (lResp.StatusCode = 200)
     and (lResp.HeaderValue('Content-Encoding') = '')
     and (lResp.Content = TEST_HTML) then
    Pass('GET /static/test.html (under threshold) -> uncompressed')
  else
    Fail('GET /static/test.html (under threshold)',
      Format('status=%d ce=%s',
        [lResp.StatusCode, lResp.HeaderValue('Content-Encoding')]));

  // ETag
  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.Get('/static/test.html');
  lEtag := lResp.HeaderValue('ETag');
  if (lResp.StatusCode = 200)
     and lEtag.StartsWith('"') and lEtag.EndsWith('"')
     and (Length(lEtag) >= 6) then
    Pass('GET /static/test.html -> 200 + quoted ETag')
  else
    Fail('GET /static/test.html (ETag stamp)',
      Format('status=%d etag=%s', [lResp.StatusCode, lEtag]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.Get('/static/test.html');
  if lResp.HeaderValue('ETag') = lEtag then
    Pass('GET /static/test.html (repeat) -> same ETag')
  else
    Fail('GET /static/test.html (repeat ETag)',
      Format('first=%s second=%s', [lEtag, lResp.HeaderValue('ETag')]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.AddHeader('If-None-Match', lEtag).Get('/static/test.html');
  if (lResp.StatusCode = 304) and (lResp.Content = '') then
    Pass('GET /static/test.html (If-None-Match match) -> 304 empty body')
  else
    Fail('GET /static/test.html (If-None-Match match)',
      Format('status=%d body=[%s]', [lResp.StatusCode, lResp.Content]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.AddHeader('If-None-Match', '"nope"').Get('/static/test.html');
  if (lResp.StatusCode = 200) and (lResp.Content = TEST_HTML) then
    Pass('GET /static/test.html (If-None-Match miss) -> 200 + body')
  else
    Fail('GET /static/test.html (If-None-Match miss)',
      Format('status=%d body=[%s]', [lResp.StatusCode, lResp.Content]));

  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.Get('/static/index.html');
  if (lResp.HeaderValue('ETag') <> '') and (lResp.HeaderValue('ETag') <> lEtag) then
    Pass('GET /static/index.html -> different ETag')
  else
    Fail('GET /static/index.html (ETag distinctness)',
      Format('index_etag=%s test_etag=%s', [lResp.HeaderValue('ETag'), lEtag]));
end;

// -- scenario 2: IPBlock blocks local request ------------------------------

procedure ConfigIPBlockBans(AEngine: TMVCEngine);
begin
  // Indy reports the loopback as the fully-expanded IPv6 form when the
  // listener binds to ::; cover both that and the IPv4 form.
  AEngine.UseHTTPFilter(IPBlock(['127.0.0.1', '::1', '0:0:0:0:0:0:0:1']));
  AEngine.Root.AsApi.MapGet('/ping',
    function: IMVCResponse
    begin
      Result := Ok('pong');
    end);
end;

procedure TestIPBlockBans(AClient: IMVCRESTClient);
begin
  AssertStatus(AClient.Get('/ping'), 403, 'IPBlock(local) -> 403');
end;

// -- scenario 3: IPBlock with non-matching list lets requests through ------

procedure ConfigIPBlockAllows(AEngine: TMVCEngine);
begin
  AEngine.UseHTTPFilter(IPBlock(['10.99.99.99']));
  AEngine.Root.AsApi.MapGet('/ping',
    function: IMVCResponse
    begin
      Result := Ok('pong');
    end);
end;

procedure TestIPBlockAllows(AClient: IMVCRESTClient);
begin
  AssertStatus(AClient.Get('/ping'), 200, 'IPBlock(other) -> 200');
end;

// -- scenario 4: RateLimit short-circuits the third request ----------------

procedure ConfigRateLimit(AEngine: TMVCEngine);
begin
  AEngine.UseHTTPFilter(RateLimit(2, 60));
  AEngine.Root.AsApi.MapGet('/ping',
    function: IMVCResponse
    begin
      Result := Ok('pong');
    end);
end;

procedure TestRateLimit(AClient: IMVCRESTClient);
var
  lResp: IMVCRESTResponse;
begin
  AssertStatus(AClient.Get('/ping'), 200, 'RateLimit req#1 -> 200');
  AssertStatus(AClient.Get('/ping'), 200, 'RateLimit req#2 -> 200');
  lResp := AClient.Get('/ping');
  if (lResp.StatusCode = 429) and (lResp.HeaderValue('Retry-After') <> '') then
    Pass('RateLimit req#3 -> 429 + Retry-After')
  else
    Fail('RateLimit req#3',
      Format('status=%d retry-after=%s',
        [lResp.StatusCode, lResp.HeaderValue('Retry-After')]));
end;

// -- scenario 5: CORS preflight + simple-header stamping -------------------

procedure ConfigCORS(AEngine: TMVCEngine);
begin
  AEngine.UseHTTPFilter(CORSFilter('https://example.com', True,
    'X-Total-Count', 'Content-Type,Authorization',
    'GET,POST,DELETE,OPTIONS', 600));
  AEngine.Root.AsApi.MapGet('/ping',
    function: IMVCResponse
    begin
      Result := Ok('pong');
    end);
end;

procedure TestCORS(AClient: IMVCRESTClient);
var
  lResp: IMVCRESTResponse;
begin
  // Preflight: OPTIONS short-circuits with 200 + full CORS headers.
  lResp := AClient.Resource('/anything').Get; // dummy noop to reuse client
  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.Resource('').Options('/anything');
  if (lResp.StatusCode = 200)
     and (lResp.HeaderValue('Access-Control-Allow-Origin') = 'https://example.com')
     and (lResp.HeaderValue('Access-Control-Allow-Credentials') = 'true')
     and (lResp.HeaderValue('Access-Control-Allow-Methods') <> '')
     and (lResp.HeaderValue('Access-Control-Allow-Headers') <> '')
     and (lResp.HeaderValue('Access-Control-Max-Age') = '600') then
    Pass('CORS preflight OPTIONS -> 200 + full header set')
  else
    Fail('CORS preflight',
      Format('status=%d origin=%s methods=%s',
        [lResp.StatusCode,
         lResp.HeaderValue('Access-Control-Allow-Origin'),
         lResp.HeaderValue('Access-Control-Allow-Methods')]));

  // Non-preflight: GET passes through; simple headers stamped.
  AClient := TMVCRESTClient.New.BaseURL(AClient.BaseURL);
  lResp := AClient.Get('/ping');
  if (lResp.StatusCode = 200)
     and (lResp.HeaderValue('Access-Control-Allow-Origin') = 'https://example.com')
     and (lResp.HeaderValue('Access-Control-Allow-Credentials') = 'true')
     and (lResp.HeaderValue('Access-Control-Expose-Headers') = 'X-Total-Count') then
    Pass('CORS GET /ping -> 200 + simple CORS headers')
  else
    Fail('CORS GET /ping',
      Format('status=%d origin=%s expose=%s',
        [lResp.StatusCode,
         lResp.HeaderValue('Access-Control-Allow-Origin'),
         lResp.HeaderValue('Access-Control-Expose-Headers')]));
end;

// -- scenario 6: RequestLog wraps everything and does not break responses --

procedure ConfigRequestLog(AEngine: TMVCEngine);
begin
  AEngine.UseHTTPFilter(RequestLog());
  AEngine.Root.AsApi.MapGet('/ping',
    function: IMVCResponse
    begin
      Result := Ok('pong');
    end);
end;

procedure TestRequestLog(AClient: IMVCRESTClient);
begin
  // The point of this test is just that RequestLog does not corrupt the
  // response. The log emission itself is visible in the console output.
  AssertStatus(AClient.Get('/ping'), 200, 'RequestLog passthrough -> 200');
end;

begin
  IsMultiThread := True;
  try
    SetupFixtures;

    WithEngine(PORT_BASE,     ConfigStatic,         TestStatic);
    WithEngine(PORT_BASE + 1, ConfigIPBlockBans,    TestIPBlockBans);
    WithEngine(PORT_BASE + 2, ConfigIPBlockAllows,  TestIPBlockAllows);
    WithEngine(PORT_BASE + 3, ConfigRateLimit,      TestRateLimit);
    WithEngine(PORT_BASE + 4, ConfigCORS,           TestCORS);
    WithEngine(PORT_BASE + 5, ConfigRequestLog,     TestRequestLog);
  except
    on E: Exception do
    begin
      WriteLn('[CRASH] ', E.ClassName, ': ', E.Message);
      Inc(GFailures);
    end;
  end;

  WriteLn;
  if GFailures = 0 then
  begin
    WriteLn('ALL PASS');
    ExitCode := 0;
  end
  else
  begin
    WriteLn('FAILURES: ', GFailures);
    ExitCode := 1;
  end;
end.
