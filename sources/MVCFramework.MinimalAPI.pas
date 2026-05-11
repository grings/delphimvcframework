// ***************************************************************************
//
// Delphi MVC Framework
//
// Copyright (c) 2010-2026 Daniele Teti and the DMVCFramework Team
//
// https://github.com/danieleteti/delphimvcframework
//
// ***************************************************************************
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// ***************************************************************************
//
// Minimal API support for DMVCFramework. EXPERIMENTAL / PREVIEW.
//
// Lets you register routes via lambda handlers without declaring a
// controller class:
//
//   lEngine
//     .MapGet('/health',
//       function: IMVCResponse
//       begin
//         Result := OkResponse('OK');
//       end)
//     .MapPost<TPerson, IPeopleService>('/people',
//       function (Person: TPerson; Svc: IPeopleService): IMVCResponse
//       begin
//         Svc.Create(Person);
//         Result := CreatedResponse('', Person);
//       end);
//
// Arguments are bound by type:
//   * TWebContext            -> request context
//   * Interface in container -> DI service
//   * Class in container     -> DI service
//   * Class not in container -> body JSON (POST/PUT/PATCH) or query (GET/DELETE)
//   * Record                 -> hybrid binding via [MVCFromBody]/[MVCFromQueryString]/
//                               [MVCFromHeader]/[MVCFromCookie] on fields
//   * Primitive (Integer, Int64, string, Boolean, Double, TGUID, TDateTime...)
//                            -> route param (if present), else query string
//
// Up to 4 generic arguments per Map call.
//
// ***************************************************************************

unit MVCFramework.MinimalAPI;

{$I dmvcframework.inc}

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  System.Rtti,
  System.TypInfo,
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.Container;

type
  EMVCMinimalAPI = class(EMVCException);

  // -------------------------------------------------------------------------
  // Handler types: function returning IMVCResponse with 0..4 typed arguments.
  // -------------------------------------------------------------------------

  TMVCMinimalFunc = reference to function: IMVCResponse;
  TMVCMinimalFunc<T1> = reference to function(Arg1: T1): IMVCResponse;
  TMVCMinimalFunc<T1, T2> = reference to function(Arg1: T1; Arg2: T2): IMVCResponse;
  TMVCMinimalFunc<T1, T2, T3> = reference to function(Arg1: T1; Arg2: T2; Arg3: T3): IMVCResponse;
  TMVCMinimalFunc<T1, T2, T3, T4> = reference to function(Arg1: T1; Arg2: T2; Arg3: T3; Arg4: T4): IMVCResponse;

  // Internal thunk: untyped wrapper invoked by the dispatcher.
  TMVCMinimalThunk = reference to function(const AContext: TWebContext;
    const ARenderer: TMVCRenderer): IMVCResponse;

  // -------------------------------------------------------------------------
  // Endpoint filter (chain-of-responsibility, .NET-style)
  //
  // Each filter wraps the next call. Inside its body the filter MAY:
  //   * Run pre-handler logic (auth check, log REQ, start timer, ...)
  //   * Call ANext() to invoke the next filter in the chain (or, at the
  //     end of the chain, the actual handler)
  //   * Run post-handler logic (modify Result, log status, stop timer)
  //   * Wrap ANext() in a try/except to observe / replace exceptions
  //   * Wrap ANext() in a try/finally to run "always" code
  //   * Skip ANext() entirely and return its own response (short-circuit)
  //
  // Filters compose by registration order: the FIRST filter Use'd is the
  // OUTERMOST. The handler runs at the deepest nesting.
  //
  // Example (covers everything the old 4-hook API did, in one place):
  //
  //   group.Use(
  //     function (Ctx: TWebContext; Next: TMVCEndpointFilterNext): IMVCResponse
  //     var sw: TStopwatch;
  //     begin
  //       sw := TStopwatch.StartNew;
  //       Audit('REQ ' + Ctx.Request.PathInfo);
  //       try
  //         try
  //           Result := Next();
  //           Audit(Format('RES %d', [Result.StatusCode]));
  //         except
  //           on E: Exception do
  //           begin
  //             Audit('ERR ' + E.Message);
  //             raise;  // or return Status(500, ...) to swallow + replace
  //           end;
  //         end;
  //       finally
  //         Audit(Format('TIME %dms', [sw.ElapsedMilliseconds]));
  //       end;
  //     end);
  // -------------------------------------------------------------------------

  TMVCEndpointFilterNext = reference to function: IMVCResponse;
  TMVCEndpointFilter = reference to function(const AContext: TWebContext;
    const ANext: TMVCEndpointFilterNext): IMVCResponse;

  // -------------------------------------------------------------------------
  // Route registry — TMVCMinimalRoute now carries group data + hook arrays.
  // Hooks are TArray refcounted, so copying a route's hook lists is cheap.
  // -------------------------------------------------------------------------

  TMVCMinimalRoute = class
  strict private
    fVerb: TMVCHTTPMethodType;
    fPathPattern: string;
    fThunk: TMVCMinimalThunk;
    fGroupData: TObject;
    fGroupDataTypeInfo: PTypeInfo;
    fFilters: TArray<TMVCEndpointFilter>;
    fName: string;
    fMetadata: TDictionary<string, TValue>;
  public
    constructor Create(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk);
    destructor Destroy; override;
    property Verb: TMVCHTTPMethodType read fVerb;
    property PathPattern: string read fPathPattern;
    property Thunk: TMVCMinimalThunk read fThunk;
    property GroupData: TObject read fGroupData write fGroupData;
    property GroupDataTypeInfo: PTypeInfo read fGroupDataTypeInfo write fGroupDataTypeInfo;
    property Filters: TArray<TMVCEndpointFilter> read fFilters write fFilters;
    // Per-endpoint metadata for OpenAPI / introspection / auth policies.
    property Name: string read fName write fName;
    property Metadata: TDictionary<string, TValue> read fMetadata;
  end;

  // Per-endpoint chainable configuration. Returned by MapXxx — wraps the
  // just-registered route so the caller can apply WithName/WithMetadata/
  // route-scoped Use without affecting the group.
  TMVCRouteHandle = record
  strict private
    fRoute: TMVCMinimalRoute;
  public
    constructor Create(ARoute: TMVCMinimalRoute);
    // Symbolic name for the endpoint. Useful for OpenAPI operationId,
    // URL generation, logs, route enumeration, ...
    function WithName(const AName: string): TMVCRouteHandle;
    // Arbitrary key/value metadata. Consumed by future OpenAPI emitter,
    // auth policies, observability tooling, etc.
    function WithMetadata(const AKey: string; const AValue: TValue): TMVCRouteHandle;
    // Route-scoped filter, appended after the group's filter stack.
    function Use(const AFilter: TMVCEndpointFilter): TMVCRouteHandle;
    // Escape hatch: access the underlying route.
    property Route: TMVCMinimalRoute read fRoute;
  end;

  TMVCMinimalRegistry = class
  strict private
    fRoutes: TObjectList<TMVCMinimalRoute>;
    fOwnedData: TObjectList<TObject>;  // group data instances we own
  public
    constructor Create;
    destructor Destroy; override;
    function Add(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
    function TryMatch(AVerb: TMVCHTTPMethodType; const APath: string;
      const AParamsTable: TMVCRequestParamsTable;
      out ARoute: TMVCMinimalRoute): Boolean;
    // Tracks an object whose lifetime is bound to the engine. Idempotent:
    // adding the same instance twice keeps a single ownership record.
    procedure TrackOwned(AObject: TObject);
  end;

  // -------------------------------------------------------------------------
  // Synthetic renderer used to render IMVCResponse from middleware.
  // Acts as a TMVCRenderer with engine wiring, no controller class needed.
  // Carries a reference to the matched route so the resolver can read group
  // data without any thread-local state. The reference is cleared when the
  // renderer is freed (per-request lifecycle).
  // -------------------------------------------------------------------------

  TMVCMinimalRenderer = class(TMVCRenderer)
  strict private
    fRoute: TMVCMinimalRoute;
  public
    property Route: TMVCMinimalRoute read fRoute write fRoute;
  end;

  // -------------------------------------------------------------------------
  // Argument resolver: type-driven binding.
  // -------------------------------------------------------------------------

  TMVCMinimalArgResolver = class
  public
    // Helpers used by Resolve<T>. Must be declared in interface because
    // Resolve<T> is a generic method of an interface-section class.
    class function ConvertStringTo(const AValue: string;
      ATypeInfo: PTypeInfo): TValue; static;
    class function BindRecordHybrid(const AContext: TWebContext;
      const ARecordTypeInfo: PTypeInfo;
      const ABoundObjects: TObjectList<TObject>): TValue; static;
    class function TryResolveDIService(const AContext: TWebContext;
      const ATypeInfo: PTypeInfo; out AService: IInterface): Boolean; static;
    class function IsHTTPMethodWithBody(
      const AMethod: TMVCHTTPMethodType): Boolean; static;
    class function GetParamFromContext(const AContext: TWebContext;
      const AName: string; out AValue: string): Boolean; static;

    class function Resolve<T>(const AContext: TWebContext;
      const ARenderer: TMVCRenderer;
      const ABoundObjects: TObjectList<TObject>): T; static;
  end;

  // -------------------------------------------------------------------------
  // Thunk factory: wraps a typed user handler in an untyped TMVCMinimalThunk
  // that resolves arguments by type at dispatch time.
  // Standalone generic functions are not allowed in Delphi — these MUST be
  // class static methods.
  // -------------------------------------------------------------------------

  TMVCThunkFactory = class
  public
    class function Make0(const AHandler: TMVCMinimalFunc): TMVCMinimalThunk; static;
    class function Make1<T1>(const AHandler: TMVCMinimalFunc<T1>): TMVCMinimalThunk; static;
    class function Make2<T1, T2>(const AHandler: TMVCMinimalFunc<T1, T2>): TMVCMinimalThunk; static;
    class function Make3<T1, T2, T3>(const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCMinimalThunk; static;
    class function Make4<T1, T2, T3, T4>(const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCMinimalThunk; static;
  end;

  // -------------------------------------------------------------------------
  // Route group: a path prefix + optional typed group data + lifecycle hooks
  // shared by all routes registered via the group. Immutable record: every
  // OnXxx / Prefix call returns a new group with the change applied; this
  // makes route grouping side-effect-free and chainable.
  // -------------------------------------------------------------------------

  TMVCRouteGroup<T: class> = record
  strict private
    fEngine: TMVCEngine;
    fPrefix: string;
    fData: T;
    fFilters: TArray<TMVCEndpointFilter>;
    function RegisterRoute(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
    function RegisterMany(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; AThunk: TMVCMinimalThunk): TMVCRouteHandle;
  public
    class function Create(AEngine: TMVCEngine; const APrefix: string;
      const AData: T): TMVCRouteGroup<T>; static;

    // Nested grouping (same data type — extends the prefix, copies filters).
    function Prefix(const APath: string): TMVCRouteGroup<T>; overload;

    // Nested grouping with NEW typed group data. Filters are NOT inherited
    // across type boundaries — re-apply them with Use() if needed.
    function Prefix<U: class>(const APath: string; const AData: U;
      AOwns: Boolean = True): TMVCRouteGroup<U>; overload;

    // Endpoint filter (chain-of-responsibility). Filters are stacked in
    // registration order: the first one Use'd is the outermost.
    function Use(const AFilter: TMVCEndpointFilter): TMVCRouteGroup<T>;

    // GET
    function MapGet(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapGet<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapGet<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapGet<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapGet<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;

    // POST
    function MapPost(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapPost<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapPost<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapPost<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapPost<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;

    // PUT
    function MapPut(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapPut<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapPut<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapPut<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapPut<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;

    // DELETE
    function MapDelete(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapDelete<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapDelete<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapDelete<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapDelete<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;

    // PATCH
    function MapPatch(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapPatch<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapPatch<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapPatch<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapPatch<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;

    // Multi-verb shortcut. Registers the same handler against every verb
    // in the array. The arity overloads mirror the single-verb Map* set.
    function MapMethods(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; const AHandler: TMVCMinimalFunc): TMVCRouteHandle; overload;
    function MapMethods<T1>(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle; overload;
    function MapMethods<T1, T2>(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle; overload;
    function MapMethods<T1, T2, T3>(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle; overload;
    function MapMethods<T1, T2, T3, T4>(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle; overload;
  end;

  // -------------------------------------------------------------------------
  // Middleware that performs route matching + handler dispatch.
  // Registered lazily on the engine at first MapXxx call.
  // -------------------------------------------------------------------------

  TMVCMinimalAPIMiddleware = class(TInterfacedObject, IMVCMiddleware)
  strict private
    fRegistry: TMVCMinimalRegistry;
    fEngine: TMVCEngine;
  protected
    procedure OnBeforeRouting(AContext: TWebContext; var AHandled: Boolean);
    procedure OnBeforeControllerAction(AContext: TWebContext;
      const AControllerQualifiedClassName: string; const AActionName: string;
      var AHandled: Boolean);
    procedure OnAfterControllerAction(AContext: TWebContext;
      const AControllerQualifiedClassName: string; const AActionName: string;
      const AHandled: Boolean);
    procedure OnAfterRouting(AContext: TWebContext; const AHandled: Boolean);
  public
    constructor Create(AEngine: TMVCEngine);
    destructor Destroy; override;
    property Registry: TMVCMinimalRegistry read fRegistry;
  end;

  // -------------------------------------------------------------------------
  // Class helper extending TMVCEngine with MapGet/MapPost/MapPut/MapDelete/MapPatch.
  // -------------------------------------------------------------------------

  TMVCEngineMinimalAPIHelper = class helper for TMVCEngine
  strict private
    function GetOrCreateMiddleware: TMVCMinimalAPIMiddleware;
    function MapInternal(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk): TMVCEngine;
  public
    function Root: TMVCRouteGroup<TObject>;


    // Open a route group with a path prefix. Without group data, T = TObject
    // and the data slot is nil (no group-data resolution happens in handlers).
    function Prefix(const APrefix: string): TMVCRouteGroup<TObject>; overload;

    // Open a route group with typed group data. The data instance is bound
    // to the engine's lifetime: it will be freed at engine shutdown unless
    // AOwns is False (in which case the caller manages the lifetime).
    function Prefix<T: class>(const APrefix: string; const AData: T;
      AOwns: Boolean = True): TMVCRouteGroup<T>; overload;

    // Internal: wires a route into the registry from a TMVCRouteGroup<T>.
    function RegisterFromGroup(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk): TMVCMinimalRoute;

    // Engine-level Map* (no prefix, no group data, no hooks)

    // GET
    function MapGet(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCEngine; overload;
    function MapGet<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCEngine; overload;
    function MapGet<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine; overload;
    function MapGet<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine; overload;
    function MapGet<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine; overload;

    // POST
    function MapPost(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCEngine; overload;
    function MapPost<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCEngine; overload;
    function MapPost<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine; overload;
    function MapPost<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine; overload;
    function MapPost<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine; overload;

    // PUT
    function MapPut(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCEngine; overload;
    function MapPut<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCEngine; overload;
    function MapPut<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine; overload;
    function MapPut<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine; overload;
    function MapPut<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine; overload;

    // DELETE
    function MapDelete(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCEngine; overload;
    function MapDelete<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCEngine; overload;
    function MapDelete<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine; overload;
    function MapDelete<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine; overload;
    function MapDelete<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine; overload;

    // PATCH
    function MapPatch(const APath: string;
      const AHandler: TMVCMinimalFunc): TMVCEngine; overload;
    function MapPatch<T1>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1>): TMVCEngine; overload;
    function MapPatch<T1, T2>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine; overload;
    function MapPatch<T1, T2, T3>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine; overload;
    function MapPatch<T1, T2, T3, T4>(const APath: string;
      const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine; overload;
  end;

implementation

uses
  System.StrUtils,
  MVCFramework.Router,
  MVCFramework.Rtti.Utils,
  MVCFramework.Serializer.Commons,
  MVCFramework.Serializer.Intf,
  MVCFramework.Serializer.JsonDataObjects,
  MVCFramework.Validation,
  MVCFramework.ValidationEngine;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalRoute                                                           }
{ -------------------------------------------------------------------------- }

constructor TMVCMinimalRoute.Create(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk);
begin
  inherited Create;
  fVerb := AVerb;
  fPathPattern := APath;
  fThunk := AThunk;
  fMetadata := TDictionary<string, TValue>.Create;
end;

destructor TMVCMinimalRoute.Destroy;
begin
  fMetadata.Free;
  inherited;
end;

{ -------------------------------------------------------------------------- }
{ TMVCRouteHandle                                                            }
{ -------------------------------------------------------------------------- }

constructor TMVCRouteHandle.Create(ARoute: TMVCMinimalRoute);
begin
  fRoute := ARoute;
end;

function TMVCRouteHandle.WithName(const AName: string): TMVCRouteHandle;
begin
  fRoute.Name := AName;
  Result := Self;
end;

function TMVCRouteHandle.WithMetadata(const AKey: string;
  const AValue: TValue): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue(AKey, AValue);
  Result := Self;
end;

function TMVCRouteHandle.Use(const AFilter: TMVCEndpointFilter): TMVCRouteHandle;
var
  lLen: Integer;
  lArr: TArray<TMVCEndpointFilter>;
begin
  lArr := fRoute.Filters;
  lLen := Length(lArr);
  SetLength(lArr, lLen + 1);
  lArr[lLen] := AFilter;
  fRoute.Filters := lArr;
  Result := Self;
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalRegistry                                                        }
{ -------------------------------------------------------------------------- }

constructor TMVCMinimalRegistry.Create;
begin
  inherited Create;
  fRoutes := TObjectList<TMVCMinimalRoute>.Create(True);
  // OwnsObjects=True: group data freed at registry destroy.
  fOwnedData := TObjectList<TObject>.Create(True);
end;

destructor TMVCMinimalRegistry.Destroy;
begin
  fRoutes.Free;
  fOwnedData.Free;
  inherited;
end;

function TMVCMinimalRegistry.Add(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
begin
  Result := TMVCMinimalRoute.Create(AVerb, APath, AThunk);
  fRoutes.Add(Result);
end;

procedure TMVCMinimalRegistry.TrackOwned(AObject: TObject);
begin
  if AObject = nil then
    Exit;
  // idempotent: same instance registered twice -> only one entry, freed once
  if fOwnedData.IndexOf(AObject) < 0 then
    fOwnedData.Add(AObject);
end;

// Apply a route constraint to a captured segment value. Returns False if the
// constraint rejects the value — the entire route then fails to match,
// letting the dispatcher consider other routes. Unknown constraint names
// are silently accepted (treated as "no constraint") so adding new ones
// later doesn't break existing routes.
function ApplyConstraint(const AConstraint, AValue: string): Boolean;
var
  lInt: Integer;
  lInt64: Int64;
  lFloat: Double;
  lGuid: TGUID;
  lDate: TDateTime;
begin
  if AConstraint = '' then Exit(True);
  if SameText(AConstraint, 'int') then
    Exit(TryStrToInt(AValue, lInt));
  if SameText(AConstraint, 'int64') then
    Exit(TryStrToInt64(AValue, lInt64));
  if SameText(AConstraint, 'float') then
    Exit(TryStrToFloat(AValue, lFloat, TFormatSettings.Invariant));
  if SameText(AConstraint, 'bool') then
  begin
    Result := SameText(AValue, 'true') or SameText(AValue, 'false')
      or (AValue = '0') or (AValue = '1');
    Exit;
  end;
  if SameText(AConstraint, 'guid') then
  begin
    try
      lGuid := StringToGUID('{' + AValue.Replace('{', '').Replace('}', '') + '}');
      Exit(True);
    except
      Exit(False);
    end;
  end;
  if SameText(AConstraint, 'date') then
    Exit(TryStrToDate(AValue, lDate, TFormatSettings.Invariant));
  Result := True; // unknown constraint -> accept
end;

function MatchPath(const APattern, APath: string;
  const AParamsTable: TMVCRequestParamsTable): Boolean;
var
  lPatternSegs, lPathSegs: TArray<string>;
  I, lColon: Integer;
  lPSeg, lASeg, lInner, lParamName, lConstraint: string;
begin
  // Segment matcher with optional constraints. Syntax:
  //   ($name)               unconstrained capture
  //   ($name:int)           accept only integers
  //   ($name:int64|guid|bool|float|date)  one of the predefined kinds
  // Static segments match literally. A failed constraint makes the whole
  // pattern fail to match (the dispatcher moves on to the next route).
  if (APattern = APath) or ((APath = '/') and (APattern = '')) then
    Exit(True);

  lPatternSegs := APattern.Trim(['/']).Split(['/']);
  lPathSegs := APath.Trim(['/']).Split(['/']);

  if Length(lPatternSegs) <> Length(lPathSegs) then
    Exit(False);

  for I := 0 to High(lPatternSegs) do
  begin
    lPSeg := lPatternSegs[I];
    lASeg := lPathSegs[I];
    if lPSeg.StartsWith('($') and lPSeg.EndsWith(')') then
    begin
      lInner := Copy(lPSeg, 3, Length(lPSeg) - 3);
      lColon := Pos(':', lInner);
      if lColon > 0 then
      begin
        lParamName := Copy(lInner, 1, lColon - 1);
        lConstraint := Copy(lInner, lColon + 1, MaxInt);
      end
      else
      begin
        lParamName := lInner;
        lConstraint := '';
      end;
      if not ApplyConstraint(lConstraint, lASeg) then
        Exit(False);
      AParamsTable.AddOrSetValue(lParamName, lASeg);
    end
    else if not SameText(lPSeg, lASeg) then
      Exit(False);
  end;
  Result := True;
end;

function TMVCMinimalRegistry.TryMatch(AVerb: TMVCHTTPMethodType;
  const APath: string; const AParamsTable: TMVCRequestParamsTable;
  out ARoute: TMVCMinimalRoute): Boolean;
var
  I: Integer;
  lRoute: TMVCMinimalRoute;
begin
  Result := False;
  ARoute := nil;
  for I := 0 to fRoutes.Count - 1 do
  begin
    lRoute := fRoutes[I];
    if lRoute.Verb <> AVerb then
      Continue;
    AParamsTable.Clear;
    if MatchPath(lRoute.PathPattern, APath, AParamsTable) then
    begin
      ARoute := lRoute;
      Exit(True);
    end;
  end;
  AParamsTable.Clear;
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalArgResolver — helpers (must be class methods because Resolve<T> }
{ is a generic method declared in interface section)                         }
{ -------------------------------------------------------------------------- }

class function TMVCMinimalArgResolver.ConvertStringTo(const AValue: string;
  ATypeInfo: PTypeInfo): TValue;
var
  lInt64: Int64;
  lInt: Integer;
  lDouble: Double;
  lBool: Boolean;
  lDateTime: TDateTime;
  lGuid: TGUID;
begin
  if ATypeInfo = TypeInfo(string) then
    Exit(TValue.From<string>(AValue));

  if ATypeInfo = TypeInfo(Integer) then
  begin
    if not TryStrToInt(AValue, lInt) then
      raise EMVCMinimalAPI.CreateFmt(http_status.BadRequest,
        'Cannot convert "%s" to Integer', [AValue]);
    Exit(TValue.From<Integer>(lInt));
  end;

  if ATypeInfo = TypeInfo(Int64) then
  begin
    if not TryStrToInt64(AValue, lInt64) then
      raise EMVCMinimalAPI.CreateFmt(http_status.BadRequest,
        'Cannot convert "%s" to Int64', [AValue]);
    Exit(TValue.From<Int64>(lInt64));
  end;

  if ATypeInfo = TypeInfo(Boolean) then
  begin
    if SameText(AValue, 'true') or (AValue = '1') then
      lBool := True
    else if SameText(AValue, 'false') or (AValue = '0') or AValue.IsEmpty then
      lBool := False
    else
      raise EMVCMinimalAPI.CreateFmt(http_status.BadRequest,
        'Cannot convert "%s" to Boolean', [AValue]);
    Exit(TValue.From<Boolean>(lBool));
  end;

  if (ATypeInfo = TypeInfo(Double)) or (ATypeInfo = TypeInfo(Single))
    or (ATypeInfo = TypeInfo(Extended)) then
  begin
    if not TryStrToFloat(AValue, lDouble, TFormatSettings.Invariant) then
      raise EMVCMinimalAPI.CreateFmt(http_status.BadRequest,
        'Cannot convert "%s" to Float', [AValue]);
    Exit(TValue.From<Double>(lDouble));
  end;

  if (ATypeInfo = TypeInfo(TDateTime))
    or (ATypeInfo = TypeInfo(TDate))
    or (ATypeInfo = TypeInfo(TTime)) then
  begin
    lDateTime := ISOTimeStampToDateTime(AValue);
    Exit(TValue.From<TDateTime>(lDateTime));
  end;

  if ATypeInfo = TypeInfo(TGUID) then
  begin
    lGuid := StringToGUID('{' + AValue.Replace('{', '').Replace('}', '') + '}');
    Exit(TValue.From<TGUID>(lGuid));
  end;

  raise EMVCMinimalAPI.CreateFmt(http_status.InternalServerError,
    'Unsupported primitive type "%s" for Minimal API parameter binding',
    [ATypeInfo.Name]);
end;

class function TMVCMinimalArgResolver.GetParamFromContext(const AContext: TWebContext;
  const AName: string; out AValue: string): Boolean;
begin
  // 1. route segment
  if AContext.Request.SegmentParam(AName, AValue) then
    Exit(True);
  // 2. query string
  if AContext.Request.QueryStringParamExists(AName) then
  begin
    AValue := AContext.Request.QueryStringParam(AName);
    Result := True;
    Exit;
  end;
  AValue := '';
  Result := False;
end;

class function TMVCMinimalArgResolver.BindRecordHybrid(const AContext: TWebContext;
  const ARecordTypeInfo: PTypeInfo;
  const ABoundObjects: TObjectList<TObject>): TValue;
var
  lCtx: TRttiContext;
  lType: TRttiType;
  lField: TRttiField;
  lAttr: TCustomAttribute;
  lFromBody: MVCFromBodyAttribute;
  lFromQuery: MVCFromQueryStringAttribute;
  lFromHeader: MVCFromHeaderAttribute;
  lFromCookie: MVCFromCookieAttribute;
  lStrValue: string;
  lFieldValue: TValue;
  lBuf: array of Byte;
  lAddr: Pointer;
  lBound: Boolean;
  lBodyObj: TObject;
  lSerializer: IMVCSerializer;
begin
  lCtx := TRttiContext.Create;
  try
    lType := lCtx.GetType(ARecordTypeInfo);
    if lType = nil then
      raise EMVCMinimalAPI.Create(http_status.InternalServerError,
        'Cannot get RTTI for record ' + string(ARecordTypeInfo.Name));

    SetLength(lBuf, lType.TypeSize);
    FillChar(lBuf[0], lType.TypeSize, 0);
    lAddr := @lBuf[0];

    for lField in lType.GetFields do
    begin
      lBound := False;
      lFromBody := nil;
      lFromQuery := nil;
      lFromHeader := nil;
      lFromCookie := nil;

      for lAttr in lField.GetAttributes do
      begin
        if lAttr is MVCFromBodyAttribute then
          lFromBody := MVCFromBodyAttribute(lAttr)
        else if lAttr is MVCFromQueryStringAttribute then
          lFromQuery := MVCFromQueryStringAttribute(lAttr)
        else if lAttr is MVCFromHeaderAttribute then
          lFromHeader := MVCFromHeaderAttribute(lAttr)
        else if lAttr is MVCFromCookieAttribute then
          lFromCookie := MVCFromCookieAttribute(lAttr);
      end;

      if lFromBody <> nil then
      begin
        if lField.FieldType.TypeKind = tkClass then
        begin
          lBodyObj := TRttiUtils.CreateObject(lField.FieldType.QualifiedName);
          ABoundObjects.Add(lBodyObj);
          lSerializer := TMVCJsonDataObjectsSerializer.Create;
          lSerializer.DeserializeObject(AContext.Request.Body, lBodyObj,
            stDefault, [], lFromBody.RootNode);
          lField.SetValue(lAddr, lBodyObj);
        end
        else if lField.FieldType.Handle = TypeInfo(string) then
          lField.SetValue(lAddr, AContext.Request.Body)
        else
          raise EMVCMinimalAPI.CreateFmt(http_status.InternalServerError,
            '[MVCFromBody] on record field "%s" supports only string or class types',
            [lField.Name]);
        lBound := True;
      end
      else if lFromQuery <> nil then
      begin
        lStrValue := AContext.Request.QueryStringParam(lFromQuery.ParamName);
        if lStrValue.IsEmpty and lFromQuery.CanBeUsedADefaultValue then
          lStrValue := lFromQuery.DefaultValueAsString;
        lFieldValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lField.FieldType.Handle);
        lField.SetValue(lAddr, lFieldValue);
        lBound := True;
      end
      else if lFromHeader <> nil then
      begin
        lStrValue := AContext.Request.Headers[lFromHeader.ParamName];
        if lStrValue.IsEmpty and lFromHeader.CanBeUsedADefaultValue then
          lStrValue := lFromHeader.DefaultValueAsString;
        lFieldValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lField.FieldType.Handle);
        lField.SetValue(lAddr, lFieldValue);
        lBound := True;
      end
      else if lFromCookie <> nil then
      begin
        lStrValue := AContext.Request.Cookie(lFromCookie.ParamName);
        if lStrValue.IsEmpty and lFromCookie.CanBeUsedADefaultValue then
          lStrValue := lFromCookie.DefaultValueAsString;
        lFieldValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lField.FieldType.Handle);
        lField.SetValue(lAddr, lFieldValue);
        lBound := True;
      end;

      if not lBound then
      begin
        // Default: try route then query, by field name (case-insensitive)
        if TMVCMinimalArgResolver.GetParamFromContext(AContext, lField.Name, lStrValue) then
        begin
          lFieldValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lField.FieldType.Handle);
          lField.SetValue(lAddr, lFieldValue);
        end;
      end;
    end;

    TValue.Make(lAddr, ARecordTypeInfo, Result);
  finally
    lCtx.Free;
  end;
end;

class function TMVCMinimalArgResolver.TryResolveDIService(const AContext: TWebContext;
  const ATypeInfo: PTypeInfo; out AService: IInterface): Boolean;
var
  lResolver: IMVCServiceContainerResolver;
begin
  Result := False;
  AService := nil;
  if ATypeInfo.Kind <> tkInterface then
    Exit;
  try
    lResolver := AContext.ServiceContainerResolver;
    if lResolver = nil then
      Exit;
    AService := lResolver.Resolve(ATypeInfo);
    Result := AService <> nil;
  except
    Result := False;
  end;
end;

class function TMVCMinimalArgResolver.IsHTTPMethodWithBody(
  const AMethod: TMVCHTTPMethodType): Boolean;
begin
  Result := AMethod in [httpPOST, httpPUT, httpPATCH];
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalArgResolver                                                     }
{ -------------------------------------------------------------------------- }

class function TMVCMinimalArgResolver.Resolve<T>(const AContext: TWebContext;
  const ARenderer: TMVCRenderer;
  const ABoundObjects: TObjectList<TObject>): T;
const
  SEG_IDX_KEY = '__mvc_minimal_seg_idx';
var
  lTypeInfo: PTypeInfo;
  lValue: TValue;
  lService: IInterface;
  lOutIntf: IInterface;
  lObj: TObject;
  lSerializer: IMVCSerializer;
  lStrValue: string;
  lParamName: string;
  lCtx: TRttiContext;
  lProps: TArray<TRttiProperty>;
  lP: TRttiProperty;
  lIdx: Integer;
  lKeys: TArray<string>;
  lIdxStr: string;
  lMinRenderer: TMVCMinimalRenderer;
begin
  lTypeInfo := TypeInfo(T);

  // 1. TWebContext
  if lTypeInfo = TypeInfo(TWebContext) then
  begin
    lValue := TValue.From<TWebContext>(AContext);
    Exit(lValue.AsType<T>);
  end;

  // 2. Interface -> DI service
  if lTypeInfo.Kind = tkInterface then
  begin
    if not TMVCMinimalArgResolver.TryResolveDIService(AContext, lTypeInfo, lService) then
      raise EMVCMinimalAPI.CreateFmt(http_status.InternalServerError,
        'Cannot resolve interface "%s" from DI container', [lTypeInfo.Name]);
    Supports(lService, lTypeInfo.TypeData.GUID, lOutIntf);
    TValue.Make(@lOutIntf, lTypeInfo, lValue);
    Exit(lValue.AsType<T>);
  end;

  // 3. Record -> hybrid binding
  if lTypeInfo.Kind = tkRecord then
  begin
    lValue := TMVCMinimalArgResolver.BindRecordHybrid(AContext, lTypeInfo, ABoundObjects);
    Exit(lValue.AsType<T>);
  end;

  // 4. Class -> precedence:
  //    a) Group data (if the active route's GroupDataTypeInfo matches T)
  //    b) Body (POST/PUT/PATCH)
  //    c) Query string mapping (GET/DELETE)
  if lTypeInfo.Kind = tkClass then
  begin
    // (a) group data lookup via the active TMVCMinimalRenderer
    if ARenderer is TMVCMinimalRenderer then
    begin
      lMinRenderer := TMVCMinimalRenderer(ARenderer);
      if (lMinRenderer.Route <> nil)
        and (lMinRenderer.Route.GroupData <> nil)
        and (lMinRenderer.Route.GroupDataTypeInfo = lTypeInfo) then
      begin
        lValue := TValue.From<TObject>(lMinRenderer.Route.GroupData);
        Exit(lValue.AsType<T>);
      end;
    end;

    lCtx := TRttiContext.Create;
    try
      lObj := TRttiUtils.CreateObject(lCtx.GetType(lTypeInfo).QualifiedName);
      ABoundObjects.Add(lObj);

      if TMVCMinimalArgResolver.IsHTTPMethodWithBody(AContext.Request.HTTPMethod) then
      begin
        if not AContext.Request.Body.Trim.IsEmpty then
        begin
          lSerializer := TMVCJsonDataObjectsSerializer.Create;
          lSerializer.DeserializeObject(AContext.Request.Body, lObj,
            stDefault, [], '');
        end;
      end
      else
      begin
        // GET/DELETE: walk public writable properties, fill from query string
        lProps := lCtx.GetType(lTypeInfo).GetProperties;
        for lP in lProps do
        begin
          if not lP.IsWritable then
            Continue;
          if AContext.Request.QueryStringParamExists(lP.Name) then
          begin
            lStrValue := AContext.Request.QueryStringParam(lP.Name);
            lP.SetValue(lObj, TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lP.PropertyType.Handle));
          end;
        end;
      end;

      // Auto-validate the bound class if it carries validation attributes
      // (descends from TMVCValidatable). Raises EMVCValidationException on
      // failure — caught by the middleware and rendered as ProblemDetails 400.
      if TMVCValidationEngine.IsValidatableClass(lObj.ClassType) then
        TMVCValidationEngine.ValidateAndRaise(lObj);
    finally
      lCtx.Free;
    end;

    lValue := TValue.From<TObject>(lObj);
    Exit(lValue.AsType<T>);
  end;

  // 5. Primitive -> next unconsumed route segment, in declaration order.
  //    A per-request counter on TWebContext.Data tracks consumption so that
  //    multiple primitive arguments map to successive segments.
  lParamName := '';
  if AContext.Request.SegmentParamsCount > 0 then
  begin
    lIdx := 0;
    if AContext.Data.ContainsKey(SEG_IDX_KEY) then
    begin
      lIdxStr := AContext.Data.Items[SEG_IDX_KEY];
      lIdx := StrToIntDef(lIdxStr, 0);
    end;

    lKeys := AContext.Request.ParamsTable.Keys.ToArray;
    if lIdx < Length(lKeys) then
    begin
      lParamName := lKeys[lIdx];
      AContext.Data.Items[SEG_IDX_KEY] := IntToStr(lIdx + 1);
    end;
  end;

  if lParamName <> '' then
    lStrValue := AContext.Request.ParamsTable.Items[lParamName]
  else
    raise EMVCMinimalAPI.CreateFmt(http_status.BadRequest,
      'No route segment available to bind primitive parameter of type "%s"',
      [lTypeInfo.Name]);

  lValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lTypeInfo);
  Result := lValue.AsType<T>;
end;

{ -------------------------------------------------------------------------- }
{ Thunk factories — capture user handler, resolve args, invoke               }
{ -------------------------------------------------------------------------- }

class function TMVCThunkFactory.Make0(
  const AHandler: TMVCMinimalFunc): TMVCMinimalThunk;
begin
  Result := function(const AContext: TWebContext;
                     const ARenderer: TMVCRenderer): IMVCResponse
    begin
      Result := AHandler();
    end;
end;

class function TMVCThunkFactory.Make1<T1>(
  const AHandler: TMVCMinimalFunc<T1>): TMVCMinimalThunk;
begin
  Result := function(const AContext: TWebContext;
                     const ARenderer: TMVCRenderer): IMVCResponse
    var
      lA1: T1;
      lBound: TObjectList<TObject>;
    begin
      lBound := TObjectList<TObject>.Create(True);
      try
        lA1 := TMVCMinimalArgResolver.Resolve<T1>(AContext, ARenderer, lBound);
        Result := AHandler(lA1);
      finally
        lBound.Free;
      end;
    end;
end;

class function TMVCThunkFactory.Make2<T1, T2>(
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCMinimalThunk;
begin
  Result := function(const AContext: TWebContext;
                     const ARenderer: TMVCRenderer): IMVCResponse
    var
      lA1: T1;
      lA2: T2;
      lBound: TObjectList<TObject>;
    begin
      lBound := TObjectList<TObject>.Create(True);
      try
        lA1 := TMVCMinimalArgResolver.Resolve<T1>(AContext, ARenderer, lBound);
        lA2 := TMVCMinimalArgResolver.Resolve<T2>(AContext, ARenderer, lBound);
        Result := AHandler(lA1, lA2);
      finally
        lBound.Free;
      end;
    end;
end;

class function TMVCThunkFactory.Make3<T1, T2, T3>(
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCMinimalThunk;
begin
  Result := function(const AContext: TWebContext;
                     const ARenderer: TMVCRenderer): IMVCResponse
    var
      lA1: T1;
      lA2: T2;
      lA3: T3;
      lBound: TObjectList<TObject>;
    begin
      lBound := TObjectList<TObject>.Create(True);
      try
        lA1 := TMVCMinimalArgResolver.Resolve<T1>(AContext, ARenderer, lBound);
        lA2 := TMVCMinimalArgResolver.Resolve<T2>(AContext, ARenderer, lBound);
        lA3 := TMVCMinimalArgResolver.Resolve<T3>(AContext, ARenderer, lBound);
        Result := AHandler(lA1, lA2, lA3);
      finally
        lBound.Free;
      end;
    end;
end;

class function TMVCThunkFactory.Make4<T1, T2, T3, T4>(
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCMinimalThunk;
begin
  Result := function(const AContext: TWebContext;
                     const ARenderer: TMVCRenderer): IMVCResponse
    var
      lA1: T1;
      lA2: T2;
      lA3: T3;
      lA4: T4;
      lBound: TObjectList<TObject>;
    begin
      lBound := TObjectList<TObject>.Create(True);
      try
        lA1 := TMVCMinimalArgResolver.Resolve<T1>(AContext, ARenderer, lBound);
        lA2 := TMVCMinimalArgResolver.Resolve<T2>(AContext, ARenderer, lBound);
        lA3 := TMVCMinimalArgResolver.Resolve<T3>(AContext, ARenderer, lBound);
        lA4 := TMVCMinimalArgResolver.Resolve<T4>(AContext, ARenderer, lBound);
        Result := AHandler(lA1, lA2, lA3, lA4);
      finally
        lBound.Free;
      end;
    end;
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalAPIMiddleware                                                   }
{ -------------------------------------------------------------------------- }

constructor TMVCMinimalAPIMiddleware.Create(AEngine: TMVCEngine);
begin
  inherited Create;
  fEngine := AEngine;
  fRegistry := TMVCMinimalRegistry.Create;
end;

destructor TMVCMinimalAPIMiddleware.Destroy;
begin
  fRegistry.Free;
  inherited;
end;

// Build a problem+json envelope (RFC 7807) from an exception. Always goes
// through the standard render pipeline so we don't poke RawWebResponse
// (which may be nil in OnBeforeRouting under some adapters).
procedure RenderExceptionAsProblem(const ARenderer: TMVCRenderer;
  const AContext: TWebContext; const AStatusCode: Integer;
  const ATitle: string; const E: Exception);
var
  lResp: IMVCResponse;
begin
  lResp := ProblemDetails(AStatusCode, ATitle, E.Message,
    AContext.Request.PathInfo);
  TMVCRenderer.InternalRenderMVCResponse(ARenderer,
    TMVCResponse(lResp as TObject));
end;

// Build the chain of TMVCEndpointFilterNext closures so the FIRST filter
// is the OUTERMOST and the handler is the innermost. Returns the closure
// that, when called, drives the entire chain.
function BuildFilterChain(const ARoute: TMVCMinimalRoute;
  const ACtx: TWebContext;
  const ARenderer: TMVCRenderer): TMVCEndpointFilterNext;
var
  i: Integer;
  lInner: TMVCEndpointFilterNext;
  lFilter: TMVCEndpointFilter;
begin
  // innermost: invoke the handler thunk
  lInner := function: IMVCResponse
    begin
      Result := ARoute.Thunk(ACtx, ARenderer);
    end;

  // wrap each filter from the LAST to the FIRST so registration order
  // becomes outer-to-inner at runtime
  for i := High(ARoute.Filters) downto 0 do
  begin
    lFilter := ARoute.Filters[i];
    // capture lInner by value into a local so the closure binds to the
    // current loop's lInner, not the next iteration's
    lInner := (function (const F: TMVCEndpointFilter;
                          const NextRef: TMVCEndpointFilterNext): TMVCEndpointFilterNext
      begin
        Result := function: IMVCResponse
          begin
            Result := F(ACtx, NextRef);
          end;
      end)(lFilter, lInner);
  end;

  Result := lInner;
end;

procedure TMVCMinimalAPIMiddleware.OnBeforeRouting(AContext: TWebContext;
  var AHandled: Boolean);
var
  lRoute: TMVCMinimalRoute;
  lRenderer: TMVCMinimalRenderer;
  lResp: IMVCResponse;
  lParamsTable: TMVCRequestParamsTable;
  lOwnedParamsTable: Boolean;
begin
  if AHandled then
    Exit;

  // The engine creates a fresh ParamsTable per request and only assigns it
  // to the context AFTER routing. At OnBeforeRouting time, AContext.ParamsTable
  // may be nil. Use any pre-existing one (e.g. set by another middleware), or
  // create a temporary one we own.
  lParamsTable := AContext.Request.ParamsTable;
  lOwnedParamsTable := False;
  if lParamsTable = nil then
  begin
    lParamsTable := TMVCRequestParamsTable.Create;
    lOwnedParamsTable := True;
  end;

  try
    if not fRegistry.TryMatch(AContext.Request.HTTPMethod,
      AContext.Request.PathInfo, lParamsTable, lRoute) then
    begin
      // No minimal-API route matched - let the regular controller router proceed.
      Exit;
    end;

    // Wire ParamsTable into the context so the resolver can read segments.
    AContext.ParamsTable := lParamsTable;

    lRenderer := TMVCMinimalRenderer.Create;
    try
      lRenderer.Engine := fEngine;
      lRenderer.SetContext(AContext);
      lRenderer.SetContentType(TMVCMediaType.APPLICATION_JSON);
      lRenderer.Route := lRoute;  // <-- gives Resolve<T> access to group data

      try
        // Build the filter chain (filters wrap the handler call). Any
        // try/except/finally semantics belong INSIDE individual filters
        // — there is no separate Before/Success/Error/Always now.
        lResp := BuildFilterChain(lRoute, AContext, lRenderer)();
        if lResp <> nil then
          TMVCRenderer.InternalRenderMVCResponse(lRenderer,
            TMVCResponse(lResp as TObject));
      except
        on E: EMVCValidationException do
          // Validation failures get the standard ProblemDetails 400 envelope.
          RenderExceptionAsProblem(lRenderer, AContext,
            http_status.BadRequest, 'Validation failed', E);
        on E: EMVCException do
          RenderExceptionAsProblem(lRenderer, AContext,
            E.HTTPStatusCode, ReasonPhraseFor(E.HTTPStatusCode), E);
        on E: Exception do
          RenderExceptionAsProblem(lRenderer, AContext,
            http_status.InternalServerError, 'Internal Server Error', E);
      end;
      AHandled := True;
    finally
      lRenderer.Route := nil;  // make the dangling-ref window minimal
      lRenderer.Free;
    end;
  finally
    if lOwnedParamsTable then
    begin
      AContext.ParamsTable := nil;
      lParamsTable.Free;
    end;
  end;
end;

procedure TMVCMinimalAPIMiddleware.OnBeforeControllerAction(
  AContext: TWebContext; const AControllerQualifiedClassName: string;
  const AActionName: string; var AHandled: Boolean);
begin
  // not used
end;

procedure TMVCMinimalAPIMiddleware.OnAfterControllerAction(
  AContext: TWebContext; const AControllerQualifiedClassName: string;
  const AActionName: string; const AHandled: Boolean);
begin
  // not used
end;

procedure TMVCMinimalAPIMiddleware.OnAfterRouting(AContext: TWebContext;
  const AHandled: Boolean);
begin
  // not used
end;

{ -------------------------------------------------------------------------- }
{ Per-engine middleware registry                                             }
{                                                                            }
{ The middleware is added to the engine's middleware list (engine owns the   }
{ interface reference). We also keep a typed pointer in this dictionary so   }
{ subsequent MapXxx calls can append to the SAME middleware's registry       }
{ without relying on interface-to-class cast tricks that are fragile across  }
{ Delphi versions.                                                           }
{ -------------------------------------------------------------------------- }

var
  gMinimalAPIByEngine: TDictionary<Pointer, TMVCMinimalAPIMiddleware> = nil;
  gMinimalAPILock: TObject = nil;

{ -------------------------------------------------------------------------- }
{ TMVCEngineMinimalAPIHelper                                                 }
{ -------------------------------------------------------------------------- }

function TMVCEngineMinimalAPIHelper.GetOrCreateMiddleware: TMVCMinimalAPIMiddleware;
begin
  TMonitor.Enter(gMinimalAPILock);
  try
    if not gMinimalAPIByEngine.TryGetValue(Pointer(Self), Result) then
    begin
      Result := TMVCMinimalAPIMiddleware.Create(Self);
      gMinimalAPIByEngine.Add(Pointer(Self), Result);
      Self.AddMiddleware(Result);
    end;
  finally
    TMonitor.Exit(gMinimalAPILock);
  end;
end;

function TMVCEngineMinimalAPIHelper.MapInternal(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCEngine;
begin
  GetOrCreateMiddleware.Registry.Add(AVerb, APath, AThunk);
  Result := Self;
end;

function TMVCEngineMinimalAPIHelper.RegisterFromGroup(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
begin
  Result := GetOrCreateMiddleware.Registry.Add(AVerb, APath, AThunk);
end;

function TMVCEngineMinimalAPIHelper.Root: TMVCRouteGroup<TObject>;
begin
  Result := Prefix('');
end;

function TMVCEngineMinimalAPIHelper.Prefix(
  const APrefix: string): TMVCRouteGroup<TObject>;
begin
  // Make sure the middleware exists (so the group has a working engine to
  // register against). No data to track.
  GetOrCreateMiddleware;
  Result := TMVCRouteGroup<TObject>.Create(Self, APrefix, nil);
end;

function TMVCEngineMinimalAPIHelper.Prefix<T>(const APrefix: string;
  const AData: T; AOwns: Boolean): TMVCRouteGroup<T>;
var
  lMW: TMVCMinimalAPIMiddleware;
begin
  lMW := GetOrCreateMiddleware;
  if AOwns and (AData <> nil) then
    lMW.Registry.TrackOwned(AData);
  Result := TMVCRouteGroup<T>.Create(Self, APrefix, AData);
end;

// ------------------ GET ------------------
function TMVCEngineMinimalAPIHelper.MapGet(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCEngine;
begin
  Result := MapInternal(httpGET, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapGet<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCEngine;
begin
  Result := MapInternal(httpGET, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapGet<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine;
begin
  Result := MapInternal(httpGET, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapGet<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine;
begin
  Result := MapInternal(httpGET, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapGet<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine;
begin
  Result := MapInternal(httpGET, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

// ------------------ POST ------------------
function TMVCEngineMinimalAPIHelper.MapPost(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCEngine;
begin
  Result := MapInternal(httpPOST, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPost<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCEngine;
begin
  Result := MapInternal(httpPOST, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPost<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine;
begin
  Result := MapInternal(httpPOST, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPost<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine;
begin
  Result := MapInternal(httpPOST, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPost<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine;
begin
  Result := MapInternal(httpPOST, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

// ------------------ PUT ------------------
function TMVCEngineMinimalAPIHelper.MapPut(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCEngine;
begin
  Result := MapInternal(httpPUT, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPut<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCEngine;
begin
  Result := MapInternal(httpPUT, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPut<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine;
begin
  Result := MapInternal(httpPUT, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPut<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine;
begin
  Result := MapInternal(httpPUT, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPut<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine;
begin
  Result := MapInternal(httpPUT, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

// ------------------ DELETE ------------------
function TMVCEngineMinimalAPIHelper.MapDelete(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCEngine;
begin
  Result := MapInternal(httpDELETE, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapDelete<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCEngine;
begin
  Result := MapInternal(httpDELETE, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapDelete<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine;
begin
  Result := MapInternal(httpDELETE, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapDelete<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine;
begin
  Result := MapInternal(httpDELETE, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapDelete<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine;
begin
  Result := MapInternal(httpDELETE, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

// ------------------ PATCH ------------------
function TMVCEngineMinimalAPIHelper.MapPatch(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCEngine;
begin
  Result := MapInternal(httpPATCH, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPatch<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCEngine;
begin
  Result := MapInternal(httpPATCH, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPatch<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCEngine;
begin
  Result := MapInternal(httpPATCH, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPatch<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCEngine;
begin
  Result := MapInternal(httpPATCH, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCEngineMinimalAPIHelper.MapPatch<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCEngine;
begin
  Result := MapInternal(httpPATCH, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

{ -------------------------------------------------------------------------- }
{ TMVCRouteGroup<T>                                                          }
{ -------------------------------------------------------------------------- }

class function TMVCRouteGroup<T>.Create(AEngine: TMVCEngine;
  const APrefix: string; const AData: T): TMVCRouteGroup<T>;
begin
  Result.fEngine := AEngine;
  Result.fPrefix := APrefix;
  Result.fData := AData;
  // hook arrays start nil — TArray refcounted assignment is no-op for nil
end;

function TMVCRouteGroup<T>.RegisterRoute(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
begin
  Result := fEngine.RegisterFromGroup(AVerb, fPrefix + APath, AThunk);
  if fData <> nil then
  begin
    Result.GroupData := TObject(fData);
    Result.GroupDataTypeInfo := TypeInfo(T);
  end;
  // copy filter array (TArray = refcount bump, near zero cost)
  Result.Filters := fFilters;
end;

function TMVCRouteGroup<T>.Prefix(const APath: string): TMVCRouteGroup<T>;
begin
  Result := Self;
  Result.fPrefix := fPrefix + APath;
end;

function TMVCRouteGroup<T>.Prefix<U>(const APath: string; const AData: U;
  AOwns: Boolean): TMVCRouteGroup<U>;
begin
  // Delegate to the engine helper so the new typed data lands in the
  // owned-data list. Hooks intentionally not propagated across type
  // boundaries — apply them on the returned group if needed.
  Result := fEngine.Prefix<U>(fPrefix + APath, AData, AOwns);
end;

// ----- endpoint filter ----------------------------------------------------

function TMVCRouteGroup<T>.Use(const AFilter: TMVCEndpointFilter): TMVCRouteGroup<T>;
var
  lLen: Integer;
begin
  // Cannot use `arr + [AFilter]` here: the compiler interprets the
  // open-array constructor over a function reference as an INVOCATION.
  // Explicit SetLength append works.
  Result := Self;
  lLen := Length(Result.fFilters);
  SetLength(Result.fFilters, lLen + 1);
  Result.fFilters[lLen] := AFilter;
end;

function TMVCRouteGroup<T>.RegisterMany(
  const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCRouteHandle;
var
  V: TMVCHTTPMethodType;
  lLast: TMVCMinimalRoute;
begin
  lLast := nil;
  for V in AVerbs do
    lLast := RegisterRoute(V, APath, AThunk);
  // The returned handle wraps the LAST verb's route. Calling WithName on it
  // names only that one — most callers don't care because MapMethods is a
  // shortcut; if you need per-verb naming, register each verb separately.
  Result := TMVCRouteHandle.Create(lLast);
end;

// ----- Map* (5 verbs x 5 arity = 25) --------------------------------------

// GET
function TMVCRouteGroup<T>.MapGet(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make0(AHandler)));
end;

function TMVCRouteGroup<T>.MapGet<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make1<T1>(AHandler)));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler)));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler)));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler)));
end;

// POST
function TMVCRouteGroup<T>.MapPost(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make0(AHandler)));
end;

function TMVCRouteGroup<T>.MapPost<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make1<T1>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler)));
end;

// PUT
function TMVCRouteGroup<T>.MapPut(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make0(AHandler)));
end;

function TMVCRouteGroup<T>.MapPut<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make1<T1>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler)));
end;

// DELETE
function TMVCRouteGroup<T>.MapDelete(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make0(AHandler)));
end;

function TMVCRouteGroup<T>.MapDelete<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make1<T1>(AHandler)));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler)));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler)));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler)));
end;

// PATCH
function TMVCRouteGroup<T>.MapPatch(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make0(AHandler)));
end;

function TMVCRouteGroup<T>.MapPatch<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make1<T1>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler)));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler)));
end;

// MapMethods (multi-verb)

function TMVCRouteGroup<T>.MapMethods(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make0(AHandler));
end;

function TMVCRouteGroup<T>.MapMethods<T1>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make1<T1>(AHandler));
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler));
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2, T3>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler));
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2, T3, T4>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler));
end;

initialization

gMinimalAPILock := TObject.Create;
gMinimalAPIByEngine := TDictionary<Pointer, TMVCMinimalAPIMiddleware>.Create;

finalization

gMinimalAPIByEngine.Free;
gMinimalAPILock.Free;

end.
