program StreamedArrayWriterSample;

// ===========================================================================
//  Explicit streamed JSON-array rendering with TMVCJSONArrayWriter.
//
//  The writer is source-agnostic: the same object streams a DB cursor, an
//  in-memory object list, or a lazy generator - element by element, directly
//  to the socket, never buffering the whole JSON payload.
//
//  Server: Indy Direct, port 8991.  DB: SQLite (people.db), 200k rows.
//
//  Routes (all return one valid JSON array):
//    GET /stream/dataset      forward-only DB cursor    -> [...]
//    GET /stream/objectlist   TObjectList<TPerson>      -> [...]
//    GET /stream/enumeration  lazy generator (no list)  -> [...]
//
//  Verify (note the absence of Content-Length: the body is streamed):
//    curl -s -D - http://localhost:8991/stream/dataset -o out.json
//
//  NB: the streaming writers require an Indy-based backend (Indy Direct or
//  WebBroker on TIdHTTPWebBrokerBridge); they cannot take over an HTTP.sys
//  socket.
// ===========================================================================

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  FireDAC.Phys.SQLite,
  FireDAC.Stan.Def,
  FireDAC.Stan.Intf,
  FireDAC.Stan.Pool,
  FireDAC.Stan.Async,
  FireDAC.Stan.Option,
  FireDAC.Stan.Error,
  FireDAC.Comp.Client,
  FireDAC.DApt,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Signal,
  MVCFramework.Logger,
  MVCFramework.Server.Intf,
  MVCFramework.Server.Factory,
  MVCFramework.ActiveRecord,
  MVCFramework.Middleware.ActiveRecord,
  MVCFramework.SQLGenerators.Sqlite,
  StreamedArrayWriterConfigU in 'StreamedArrayWriterConfigU.pas',
  PeopleSourcesU in 'PeopleSourcesU.pas',
  StreamedArrayWriterControllerU in 'StreamedArrayWriterControllerU.pas';

{$R *.res}

const
  PORT = 8991;

procedure RunServer;
var
  LEngine: TMVCEngine;
  LServer: IMVCServer;
begin
  LEngine := TMVCEngine.Create;
  try
    LEngine.AddController(TStreamedArrayWriterController);
    // Provides the request-scoped connection used by the /datasetfunc action.
    LEngine.AddMiddleware(TMVCActiveRecordMiddleware.Create(CON_DEF_NAME));

    LServer := TMVCServerFactory.CreateIndyDirect(LEngine);
    LogI('Server listening on http://localhost:%d (Indy Direct)', [PORT]);
    LogI('GET /stream/dataset      - DB cursor (raw record)   -> streamed, no CL');
    LogI('GET /stream/dbobjects    - DB cursor -> domain obj   -> streamed, no CL');
    LogI('GET /stream/objectlist   - TObjectList<TPerson>     -> streamed, no CL');
    LogI('GET /stream/enumeration  - lazy file enumerator     -> streamed, no CL');
    LogI('GET /stream/datasetfunc      - return TDataSet (0 code)    -> buffered, w/ CL');
    LogI('GET /stream/datasetstreamed  - return TMVCStreamedResponse -> chunked, keep-alive, flat RAM');
    LogI('CTRL+C to shutdown.');
    LServer.RunAndWait(PORT)
  finally
    LEngine.Free;
  end;
end;

begin
  IsMultiThread := True;
  try
    LogI('** DMVCFramework Streamed Array Writer Demo **');
    RegisterSQLiteConnectionDef;
    SeedDataset;
    SeedFileFeed;
    RunServer;
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
