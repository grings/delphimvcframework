unit StreamedArrayWriterControllerU;

// ===========================================================================
//  Explicit streamed JSON-array rendering with TMVCJSONArrayWriter.
//
//  Unlike the "streaming_json_dataset" sample (where you just RETURN a
//  TDataSet and the framework's streaming serializer emits it for you), here
//  the action drives the loop itself: it opens "[", pushes one JSON value per
//  iteration straight to the socket, and closes "]". Between iterations only
//  the running element lives in memory, so server RAM stays flat no matter how
//  many elements are emitted.
//
//  The point of this sample: the writer is SOURCE-AGNOSTIC. Send() takes any
//  complete JSON value, so the very same writer streams:
//    - a forward-only DB cursor, raw record shape   (/stream/dataset)
//    - a forward-only DB cursor mapped to a domain   (/stream/dbobjects)
//      object one row at a time
//    - a fully loaded TObjectList<T>                 (/stream/objectlist)
//    - a lazy object enumerator over a file          (/stream/enumeration)
//      (or any external source)
// ===========================================================================

interface

uses
  Data.DB,
  MVCFramework, MVCFramework.Commons;

type
  [MVCPath('/stream')]
  TStreamedArrayWriterController = class(TMVCController)
  public
    /// <summary>
    /// DATASET source: a forward-only FireDAC cursor (fmOnDemand +
    /// Unidirectional) streamed row by row. Neither the dataset nor the JSON
    /// is ever fully held in memory.
    /// </summary>
    [MVCPath('/dataset')]
    [MVCHTTPMethod([httpGET])]
    procedure StreamDataSet;

    /// <summary>
    /// DB-TO-OBJECT source: the same forward-only cursor, but each row is
    /// mapped to a TPerson domain object and that object is serialized (so the
    /// JSON follows the object's rules, not the raw column names). The object
    /// is created, emitted and freed inside the loop: one row + one object +
    /// one JSON value live at a time. This is the typical "hydrate an entity
    /// per row and stream it" pattern.
    /// </summary>
    [MVCPath('/dbobjects')]
    [MVCHTTPMethod([httpGET])]
    procedure StreamDBObjects;

    /// <summary>
    /// OBJECT-LIST source: a TObjectList&lt;TPerson&gt; you already have in
    /// memory, serialized one element at a time. The list itself is in memory
    /// (you built it), but the JSON payload is not - it goes to the socket
    /// element by element.
    /// </summary>
    [MVCPath('/objectlist')]
    [MVCHTTPMethod([httpGET])]
    procedure StreamObjectList;

    /// <summary>
    /// ENUMERATION source: a lazy object enumerator that reads a file one line
    /// at a time and yields one TPerson per line. The file is never loaded
    /// whole and at most one TPerson exists at any instant - the realistic
    /// "stream objects read from a file or a DB cursor" case. Works with a
    /// plain "for p in source do" loop.
    /// </summary>
    [MVCPath('/enumeration')]
    [MVCHTTPMethod([httpGET])]
    procedure StreamEnumeration;

    /// <summary>
    /// FUNCTIONAL-ACTION source (the zero-code path): just RETURN a TDataSet.
    /// The framework serializes it with the streaming JSON serializer (no JSON
    /// DOM, rows pulled on demand), so DB-side RAM stays bounded - BUT the full
    /// JSON payload is assembled in a memory stream and the response is sent
    /// WITH a Content-Length. This is "streaming serialization into a buffer",
    /// not record-by-record streaming to the socket. It works on every backend
    /// and needs no streaming code. Note the response here HAS Content-Length,
    /// unlike the four endpoints above. Connection is request-scoped (provided
    /// by TMVCActiveRecordMiddleware), so it outlives the render.
    /// </summary>
    [MVCPath('/datasetfunc')]
    [MVCHTTPMethod([httpGET])]
    function GetPeopleDataSet: TDataSet;

    /// <summary>
    /// FUNCTIONAL-ACTION + true socket streaming: return TMVCStreamedResponse.
    /// Zero loop code AND flat framework RAM AND chunked transfer (keep-alive,
    /// works on every chunked-capable client). The best of /dataset (socket
    /// streaming) and /datasetfunc (declarative return).
    /// </summary>
    [MVCPath('/datasetstreamed')]
    [MVCHTTPMethod([httpGET])]
    function GetStreamedDataSet: TMVCStreamedResponse;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  FireDAC.Comp.Client,
  FireDAC.Stan.Option,
  MVCFramework.ActiveRecord,
  MVCFramework.Serializer.Commons,
  MVCFramework.SSE.Writer,
  PeopleSourcesU,
  StreamedArrayWriterConfigU;

const
  FIRST: array [0 .. 9] of string = ('Alice', 'Bob', 'Carol', 'Daniel', 'Eve',
    'Frank', 'Grace', 'Hannah', 'Ivan', 'Julia');
  LAST: array [0 .. 9] of string = ('Bianchi', 'Rossi', 'Verdi', 'Neri',
    'Gialli', 'Bruni', 'Romano', 'Ricci', 'Greco', 'Conti');
  COUNTRIES: array [0 .. 5] of string = ('IT', 'FR', 'DE', 'ES', 'NL', 'PT');

{ TStreamedArrayWriterController }

procedure TStreamedArrayWriterController.StreamDataSet;
var
  lConn: TFDConnection;
  lQry: TFDQuery;
  lWriter: TMVCJSONArrayWriter;
begin
  lConn := TFDConnection.Create(nil);
  try
    lConn.ConnectionDefName := CON_DEF_NAME;
    lConn.Open;

    lQry := TFDQuery.Create(nil);
    try
      lQry.Connection := lConn;
      // Forward-only streaming cursor: rows are fetched on demand as Next is
      // called, so the full result is never materialized server-side.
      lQry.FetchOptions.Mode := TFDFetchMode.fmOnDemand;
      lQry.FetchOptions.Unidirectional := True;
      lQry.UpdateOptions.ReadOnly := True;
      lQry.UpdateOptions.RequestLive := False;
      lQry.Open('SELECT id, full_name, country, age FROM people ORDER BY id');

      lWriter := TMVCJSONArrayWriter.Create(Context);
      try
        while not lQry.Eof do
        begin
          if not lWriter.Connected then // client disconnected: stop early
            Break;
          lWriter.Send(Serializer.SerializeDataSetRecord(lQry));
          lQry.Next;
        end;
      finally
        lWriter.Free; // emits the closing "]" and closes the socket
      end;
    finally
      lQry.Free;
    end;
  finally
    lConn.Free;
  end;
end;

procedure TStreamedArrayWriterController.StreamDBObjects;
var
  lConn: TFDConnection;
  lQry: TFDQuery;
  lWriter: TMVCJSONArrayWriter;
  lPerson: TPerson;
begin
  lConn := TFDConnection.Create(nil);
  try
    lConn.ConnectionDefName := CON_DEF_NAME;
    lConn.Open;

    lQry := TFDQuery.Create(nil);
    try
      lQry.Connection := lConn;
      // Same forward-only streaming cursor as /dataset.
      lQry.FetchOptions.Mode := TFDFetchMode.fmOnDemand;
      lQry.FetchOptions.Unidirectional := True;
      lQry.UpdateOptions.ReadOnly := True;
      lQry.UpdateOptions.RequestLive := False;
      lQry.Open('SELECT id, full_name, country, age FROM people ORDER BY id');

      lWriter := TMVCJSONArrayWriter.Create(Context);
      try
        while not lQry.Eof do
        begin
          if not lWriter.Connected then
            Break;
          // Hydrate one domain object from the current row, serialize it with
          // the object's own rules, then discard it. Only one row, one object
          // and one JSON value are alive at any instant.
          lPerson := TPerson.Create(
            lQry.FieldByName('id').AsInteger,
            lQry.FieldByName('full_name').AsString,
            lQry.FieldByName('country').AsString,
            lQry.FieldByName('age').AsInteger);
          try
            lWriter.Send(Serializer.SerializeObject(lPerson));
          finally
            lPerson.Free;
          end;
          lQry.Next;
        end;
      finally
        lWriter.Free;
      end;
    finally
      lQry.Free;
    end;
  finally
    lConn.Free;
  end;
end;

procedure TStreamedArrayWriterController.StreamObjectList;
var
  lPeople: TObjectList<TPerson>;
  lWriter: TMVCJSONArrayWriter;
  lPerson: TPerson;
  I: Integer;
begin
  // A collection you already hold in memory (e.g. the result of a service
  // call). It is materialized in full, but we still stream the JSON element by
  // element rather than serializing the whole collection into one big string.
  lPeople := TObjectList<TPerson>.Create(True);
  try
    for I := 1 to 50000 do
      lPeople.Add(TPerson.Create(I, FIRST[I mod 10] + ' ' + LAST[(I div 10) mod 10],
        COUNTRIES[I mod 6], 18 + (I mod 62)));

    lWriter := TMVCJSONArrayWriter.Create(Context);
    try
      for lPerson in lPeople do
      begin
        if not lWriter.Connected then
          Break;
        lWriter.Send(Serializer.SerializeObject(lPerson));
      end;
    finally
      lWriter.Free;
    end;
  finally
    lPeople.Free;
  end;
end;

procedure TStreamedArrayWriterController.StreamEnumeration;
var
  lSource: TPersonFileSource;
  lWriter: TMVCJSONArrayWriter;
  lPerson: TPerson;
begin
  // Lazy source: the enumerator reads the feed file one line at a time and
  // yields one TPerson per line. Nothing is pre-loaded - neither the file nor
  // the objects nor the JSON ever exist in full. The same shape works for a
  // DB cursor, a network stream, etc.
  lSource := TPersonFileSource.Create(GetPeopleFeedPath);
  try
    lWriter := TMVCJSONArrayWriter.Create(Context);
    try
      for lPerson in lSource do
      begin
        if not lWriter.Connected then
          Break;
        lWriter.Send(Serializer.SerializeObject(lPerson));
      end;
    finally
      lWriter.Free;
    end;
  finally
    lSource.Free;
  end;
end;

function TStreamedArrayWriterController.GetPeopleDataSet: TDataSet;
begin
  // Zero streaming code: return the dataset, the framework streams it for you.
  // SelectUnidirectionalDataSet keeps the DB cursor forward-only, so the DB
  // side stays bounded. The engine frees the returned dataset after rendering;
  // the AR middleware owns the request-scoped connection.
  Result := TMVCActiveRecord.SelectUnidirectionalDataSet(
    'SELECT id, full_name, country, age FROM people ORDER BY id', []);
end;

function TStreamedArrayWriterController.GetStreamedDataSet: TMVCStreamedResponse;
begin
  // Declarative + true socket streaming: wrap the dataset in TMVCStreamedResponse.
  // The framework flushes rows directly to the socket as chunked transfer
  // (Transfer-Encoding: chunked, no Content-Length), keeping framework-side
  // RAM flat for the full result set. The wrapper owns and frees the dataset
  // after rendering; the AR middleware keeps the connection alive for the
  // duration of the request.
  //
  // NOTE: TMVCRenderer(Self) is used to disambiguate from the local
  // "procedure StreamDataSet" endpoint that has the same name.
  Result := TMVCRenderer(Self).StreamDataSet(
    TMVCActiveRecord.SelectUnidirectionalDataSet(
      'SELECT id, full_name, country, age FROM people ORDER BY id', []),
    ncLowerCase, True);
end;

end.
