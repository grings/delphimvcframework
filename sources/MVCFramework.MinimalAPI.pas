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
// controller class. Every route belongs to a TMVCRouteGroup: use
// lEngine.Root for "no prefix, no group data, no filters" routes, or
// lEngine.Prefix(...) for prefixed groups (with optional typed group data
// and filter stack).
//
//   lEngine.Root
//     .MapGet('/health',
//       function: IMVCResponse
//       begin
//         Result := Ok('OK');
//       end);
//
//   lEngine.Prefix('/api/v1')
//     .Use(LoggingFilter())
//     .Use(BearerAuthFilter())
//     .MapPost<TPerson, IPeopleService>('/people',
//       function (Person: TPerson; Svc: IPeopleService): IMVCResponse
//       begin
//         Svc.Create(Person);
//         Result := Created('', Person);
//       end);
//
// Arguments are bound by type:
//   * TWebContext            -> request context
//   * Interface in container -> DI service
//   * Class in container     -> DI service
//   * Class not in container -> body JSON (POST/PUT/PATCH) or query (GET/DELETE)
//   * Record                 -> hybrid binding via [MVCFromBody]/[MVCFromQueryString]/
//                               [MVCFromHeader]/[MVCFromCookie]/[MVCFromContentField]
//                               on fields
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
  MVCFramework.Container,
  MVCFramework.JWT,                            // TJWT, TJWTCheckableClaims (JWT() helper)
  MVCFramework.Middleware.Authentication;      // IMVCAuthenticationHandler (JWT() helper)

type
  // Classifies a route registered via the minimal-API surface.
  //   rkApi  - JSON API endpoint; appears in OpenAPI by default
  //   rkWeb  - server-rendered HTML endpoint; excluded from OpenAPI by default
  // All groups start as rkApi. Call .AsWeb on a group to mark it (and every
  // route + nested sub-group it produces) as rkWeb.
  TMVCRouteKind = (rkApi, rkWeb);

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
  // HTTP filter — operates at the transport level, BEFORE routing happens.
  //
  // HTTPFilters wrap the entire minimal-API request handling (TryMatch +
  // EndpointFilter chain + render). They:
  //   * see Ctx.Request before any route is matched
  //   * mutate Ctx.Response directly (no IMVCResponse abstraction)
  //   * compose via chain-of-responsibility (Next() invokes the inner chain)
  //   * can short-circuit by NOT calling Next() — the request stops there
  //
  // Compared to EndpointFilter:
  //   * Endpoint filter: per-group, fires only when a route matches, wraps
  //     the handler. Reads/writes the semantic IMVCResponse.
  //   * HTTP filter: per-engine, fires for every request, wraps the entire
  //     dispatch including routing. Reads/writes the raw HTTP transport.
  //
  // Engine ordering: ALL HTTPFilters run BEFORE any EndpointFilter. Within
  // each kind, registration order = execution order (first registered =
  // outermost in the chain = first pre-Next code to run, last post-Next
  // code to run).
  //
  // Use cases that naturally fit HTTPFilter:
  //   * IP / geo block (pre-Next, short-circuit 403)
  //   * Rate limit (pre-Next, short-circuit 429)
  //   * Static files (pre-Next, short-circuit if file exists)
  //   * Compression / ETag (post-Next, transform Response bytes)
  //   * Security headers (post-Next, stamp on every response)
  //   * Request log / Analytics (pre+post around Next, capture timing)
  //
  // Wired on the engine via lEngine.UseHTTPFilter(...).
  // -------------------------------------------------------------------------
  TMVCHTTPFilterNext = reference to procedure;
  TMVCHTTPFilter = reference to procedure (
    const AContext: TWebContext;
    const ANext: TMVCHTTPFilterNext);

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
    fParamTypes: TArray<PTypeInfo>;
    fRouteKind: TMVCRouteKind;
    procedure SetName(const AValue: string);
  private
    // Back-reference to the registry the route belongs to. Used by SetName
    // to enforce engine-wide uniqueness of operation names. Set in
    // TMVCMinimalRegistry.Add right after construction.
    fRegistry: TObject;
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
    // Writing the Name goes through SetName, which rejects empty strings
    // and raises EMVCMinimalAPI on duplicates across the engine.
    property Name: string read fName write SetName;
    property Metadata: TDictionary<string, TValue> read fMetadata;
    // Type info for each generic handler parameter (T1, T2, T3, T4 in order).
    // Captured at registration time so OpenAPI emitter / introspection tools
    // can read the handler signature. Length() = 0 for parameter-less handlers.
    property ParamTypes: TArray<PTypeInfo> read fParamTypes write fParamTypes;
    // Classification of the route: rkApi (JSON) or rkWeb (HTML).
    // Stamped at registration time by the owning TMVCRouteGroup<T>.
    // Default rkApi via class-field zero-init.
    property RouteKind: TMVCRouteKind read fRouteKind write fRouteKind;
  end;

  // Per-endpoint chainable configuration. Returned by MapXxx — wraps the
  // just-registered route so the caller can apply typed configuration
  // (name, OpenAPI summary/description/tags/deprecated, response type)
  // and route-scoped filters without affecting the group.
  TMVCRouteHandle = record
  strict private
    fRoute: TMVCMinimalRoute;
  public
    constructor Create(ARoute: TMVCMinimalRoute);
    // Symbolic name for the endpoint. Useful for OpenAPI operationId,
    // URL generation, logs, route enumeration, ...
    // Empty names and duplicate names across the engine raise
    // EMVCMinimalAPI at registration time.
    function WithName(const AName: string): TMVCRouteHandle;
    // OpenAPI 3.x: one-line operation summary shown in Swagger UI.
    function WithSummary(const ASummary: string): TMVCRouteHandle;
    // OpenAPI 3.x: long-form operation description (Markdown allowed).
    function WithDescription(const ADescription: string): TMVCRouteHandle;
    // OpenAPI 3.x: tag(s) used by Swagger UI to group operations.
    function WithTags(const ATag: string): TMVCRouteHandle; overload;
    function WithTags(const ATags: TArray<string>): TMVCRouteHandle; overload;
    // OpenAPI 3.x: marks the operation as deprecated.
    function WithDeprecated(const AValue: Boolean = True): TMVCRouteHandle;
    // OpenAPI 3.x: declares the schema of the 200 response body.
    function Produces<T>: TMVCRouteHandle;
    // Controls OpenAPI visibility for this route. Default is the route's
    // group kind: rkApi -> visible; rkWeb -> hidden. Pass True on a web
    // route to publish it (dual-output endpoints), or False on an API
    // route to hide it (internal endpoints).
    function WithOpenAPI(const AVisible: Boolean = True): TMVCRouteHandle;
    // Route-scoped filter, appended after the group's filter stack.
    function Use(const AFilter: TMVCEndpointFilter): TMVCRouteHandle;
    // Escape hatch: access the underlying route.
    property Route: TMVCMinimalRoute read fRoute;
  end;

  // Static helpers used by the OpenAPI emitter (and other introspection
  // tools) to interpret route metadata without poking the registry directly.
  TMVCMinimalRouteHelper = class
  public
    // Returns true if the route should be emitted into OpenAPI. Resolves the
    // route's kind and the optional 'openapi.visible' metadata override.
    class function IsVisibleInOpenAPI(const ARoute: TMVCMinimalRoute): Boolean; static;
  end;

  TMVCMinimalRegistry = class
  strict private
    fRoutes: TObjectList<TMVCMinimalRoute>;
    fOwnedData: TObjectList<TObject>;  // group data instances we own
    fHTTPFilters: TArray<TMVCHTTPFilter>;
  public
    constructor Create;
    destructor Destroy; override;
    // Append an HTTP filter to the engine-wide chain. First registered is
    // outermost in the chain (runs first pre-Next, last post-Next).
    procedure AddHTTPFilter(const AFilter: TMVCHTTPFilter);
    property HTTPFilters: TArray<TMVCHTTPFilter> read fHTTPFilters;
    function Add(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
    // Route match + content negotiation. When multiple routes match the same
    // verb+path (e.g. an rkApi and an rkWeb sharing /users), the winner is
    // picked by scoring each candidate against the request's Accept and
    // Content-Type headers — rkWeb prefers text/html responses and form
    // bodies, rkApi prefers application/json responses and JSON bodies.
    // Ties resolve to the first registered candidate.
    function TryMatch(AVerb: TMVCHTTPMethodType; const APath: string;
      const AAcceptHeader: string; const AContentTypeHeader: string;
      const AParamsTable: TMVCRequestParamsTable;
      out ARoute: TMVCMinimalRoute): Boolean;
    // Tracks an object whose lifetime is bound to the engine. Idempotent:
    // adding the same instance twice keeps a single ownership record.
    procedure TrackOwned(AObject: TObject);
    // Snapshot of registered routes (for introspection: OpenAPI emitter,
    // diagnostics, route listing). Returns a copy of the internal array so
    // the caller cannot mutate the registry through it.
    function AllRoutes: TArray<TMVCMinimalRoute>;
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

    // Renders one or more server-side view templates using the engine's
    // configured TMVCViewEngineClass (TemplatePro / WebStencils / Mustache,
    // as set via TMVCEngine.SetViewEngine). Mirrors TMVCController.RenderView
    // for the minimal-API world: the data source is the per-request
    // TWebContext.ViewData populated through the global ViewData() helper,
    // since there is no controller instance to carry a FViewModel.
    function RenderView(const AViewName: string;
      const AOnBeforeRender: TMVCSSVBeforeRenderCallback = nil): string; overload;
    // AUseCommonHeadersAndFooters is accepted for API parity with
    // TMVCController.RenderViews but ignored — minimal-API handlers have no
    // per-handler page-header/footer state to wrap views with.
    function RenderViews(const AViewNames: TArray<string>;
      const AUseCommonHeadersAndFooters: Boolean = True): string; overload;
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
    fRouteKind: TMVCRouteKind;
    function RegisterRoute(AVerb: TMVCHTTPMethodType; const APath: string;
      AThunk: TMVCMinimalThunk;
      const AParamTypes: TArray<PTypeInfo>): TMVCMinimalRoute;
    function RegisterMany(const AVerbs: array of TMVCHTTPMethodType;
      const APath: string; AThunk: TMVCMinimalThunk;
      const AParamTypes: TArray<PTypeInfo>): TMVCRouteHandle;
  public
    class function Create(AEngine: TMVCEngine; const APrefix: string;
      const AData: T; ARouteKind: TMVCRouteKind = rkApi): TMVCRouteGroup<T>; static;

    // Nested grouping. Returns a new group whose path is the concatenation
    // of the parent prefix and APath; the parent's filter chain is
    // inherited (same model as ASP.NET Core MapGroup / FastAPI
    // include_router). Sub-groups CAN add more filters via Use(), they
    // cannot drop the parent's.
    function Prefix(const APath: string): TMVCRouteGroup<T>; overload;

    // Same as above, with NEW typed group data. The data instance is
    // bound to the engine's lifetime (freed at engine shutdown) unless
    // AOwns is False. Filters still inherit — typed data is the only
    // thing that changes across the boundary.
    function Prefix<U: class>(const APath: string; const AData: U;
      AOwns: Boolean = True): TMVCRouteGroup<U>; overload;

    // Endpoint filter (chain-of-responsibility). Filters are stacked in
    // registration order: the first one Use'd is the outermost.
    function Use(const AFilter: TMVCEndpointFilter): TMVCRouteGroup<T>;

    // Marks this group (and every route + nested sub-group it produces) as
    // rkWeb: HTML endpoints excluded from OpenAPI by default. Returns the
    // same group so it chains naturally with .Use(...) and .MapXxx(...).
    //
    //   lEngine.Root.AsWeb.Use(MemorySession(10)).MapGet('/', HomeHandler);
    function AsWeb: TMVCRouteGroup<T>;

    // Marks this group as rkApi (JSON, included in OpenAPI). Same as the
    // default for fresh Root/Prefix groups, but useful for reverting a
    // nested sub-group of an .AsWeb parent back to API semantics — e.g. a
    // JSON autocomplete endpoint embedded in a web app's URL tree.
    //
    //   lEngine.Root.AsWeb
    //     .Prefix('/search').AsApi
    //     .MapGet('/users.json', SearchUsersHandler);
    function AsApi: TMVCRouteGroup<T>;

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
    // Inner-most dispatch: TryMatch + EndpointFilter chain + render. Wrapped
    // by the HTTPFilter chain in OnBeforeRouting.
    procedure DoMinimalDispatch(AContext: TWebContext; var AHandled: Boolean);
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
  // Class helper extending TMVCEngine with the entry points to the minimal
  // API: Root (the top-level route group) and Prefix (a route group with a
  // path prefix and optional typed data).
  //
  // All route registration goes through a TMVCRouteGroup — there is no
  // shortcut on the engine itself. Use Root for "no prefix, no group data,
  // no filters" routes; use Prefix for everything else. This keeps the
  // engine surface small and makes the route-grouping model explicit in
  // every call site.
  //
  //   lEngine.Root.MapGet('/health', ...);
  //   lEngine.Prefix('/api/v1').Use(AuthFilter).MapGet('/users', ...);
  // -------------------------------------------------------------------------

  TMVCEngineMinimalAPIHelper = class helper for TMVCEngine
  strict private
    function GetOrCreateMiddleware: TMVCMinimalAPIMiddleware;
  public
    // The top-level route group. Equivalent to Prefix('').
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

    // Append an HTTP filter to the engine-wide chain. See TMVCHTTPFilter
    // for semantics. Returns Self via the helper so calls can chain:
    //   lEngine.UseHTTPFilter(IPBlock(banned)).UseHTTPFilter(Compression);
    function UseHTTPFilter(const AFilter: TMVCHTTPFilter): TMVCEngine;
  end;

// Returns the ViewData dictionary for the request currently being dispatched
// by the minimal-API middleware. Raises EMVCMinimalAPI if called outside a
// minimal-API request (no current context).
//
// ViewData is the only ambient per-request helper by design. It carries
// data OUT to the view engine (a different layer), so threadvar access is
// semantically the right model — it is NOT a service the handler queries.
// Everything else (TWebContext, Session, Request, Response, services from
// the DI container) must be declared as a generic argument so the resolver
// injects it. Explicit dependencies in the handler signature keep code
// testable and intent-revealing — this matches ASP.NET Core Minimal APIs,
// which deliberately removed the static ambient HttpContext.Current that
// earlier ASP.NET versions had.
function ViewData: TMVCViewDataObject;

// Renders a server-side view template using the engine's configured
// TMVCViewEngineClass (TemplatePro / WebStencils / Mustache via
// TMVCEngine.SetViewEngine). The current request's ViewData() is the data
// source; the returned IMVCResponse carries the rendered HTML body with
// Content-Type text/html; charset=utf-8 and StatusCode 200 (override on the
// returned instance: Result.StatusCode := N).
//
// Raises EMVCMinimalAPI if called outside a minimal-API request scope.
function RenderView(const AViewName: string): IMVCResponse; overload;
function RenderView(const AViewName: string;
  const AOnBeforeRender: TMVCSSVBeforeRenderCallback): IMVCResponse; overload;

// Renders multiple view templates concatenated into a single HTML body. Useful
// for header/content/footer composition.
//
// AUseCommonHeadersAndFooters is accepted for API parity with
// TMVCController.RenderViews but ignored — minimal-API handlers have no
// per-handler page-header/footer state to wrap views with.
function RenderViews(const AViewNames: TArray<string>;
  const AUseCommonHeadersAndFooters: Boolean = True): IMVCResponse;

// Returns a filter that wires an in-memory session factory onto every request
// passing through the group it is attached to (and every nested sub-group, by
// the standard filter-inheritance rules).
//
//   lEngine.Root.AsWeb
//     .Use(MemorySession(10))         // 10-minute idle timeout, no HttpOnly
//     .MapGet('/', HomeHandler);
//
// The factory is owned by the filter via an interface-managed holder, so it is
// freed when the filter is dropped (typically engine shutdown). The session
// itself is read/written via the usual TWebContext.Session API.
function MemorySession(const ATimeoutInMinutes: Integer = 0;
  const AHttpOnly: Boolean = False): TMVCEndpointFilter;

// -------------------------------------------------------------------------
// Native endpoint-filter implementations of common cross-cutting concerns.
//
// Each helper below is hand-written against the filter chain-of-
// responsibility model. Compared to the equivalent classic IMVCMiddleware,
// the filter form has one structural advantage worth using:
//
//   try
//     Result := Next();
//   finally
//     // cleanup ALWAYS runs, even if Next() raised
//   end;
//
// The 4-hook IMVCMiddleware interface (OnBeforeRouting, OnBeforeControllerAction,
// OnAfterControllerAction, OnAfterRouting) splits this across separate
// callbacks invoked at different points by the framework, so an exception in
// the handler skips the trailing hooks and leaves resources dangling (e.g.
// ActiveRecord connections not returned to the pool on a thrown handler).
// The filters below use try..finally to guarantee correct cleanup.
// -------------------------------------------------------------------------

// CORS filter. Handles preflight OPTIONS requests directly (short-circuits
// with 200 + Access-Control-* headers) and stamps the same headers on every
// other response. Defaults match the typical permissive setup used by the
// classic TMVCCORSMiddleware.
function CORS(
  const AAllowedOriginURLs: string = '*';
  const AAllowsCredentials: Boolean = True;
  const AExposeHeaders: string = '';
  const AAllowsHeaders: string = 'X-Requested-With, Content-Type, Accept, Origin, Authorization';
  const AAllowsMethods: string = 'GET, POST, PUT, DELETE, OPTIONS';
  const AAccessControlMaxAge: Integer = 86400): TMVCEndpointFilter;

// JWT bearer-auth filter. Reads the Authorization header, verifies the
// token against ASecret with AHMACAlgorithm, validates the standard claims
// listed in AClaimsToCheck, and populates Context.LoggedUser on success.
// On failure short-circuits with a 401 ProblemDetails response.
// Special-cases the configured login URL: a POST to ALoginURLSegment is
// forwarded to AAuthenticationHandler.OnAuthentication for credential
// verification, then a freshly-minted token is returned in the
// Authorization response header.
function JWT(
  const AAuthenticationHandler: IMVCAuthenticationHandler;
  const AClaimsSetup: TJWTClaimsSetup;
  const ASecret: string = 'D3lph1MVCFram3w0rk';
  const ALoginURLSegment: string = '/login';
  const AClaimsToCheck: TJWTCheckableClaims = [];
  const ALeewaySeconds: Cardinal = 300;
  const AHMACAlgorithm: string = 'HS512'): TMVCEndpointFilter;

// ActiveRecord lifecycle filter. Acquires a FireDAC connection from the
// FDManager pool keyed by ADefaultConnectionDefName before the handler
// runs and releases it inside a `finally` so the connection is returned
// to the pool even when the handler raises. The FireDAC connection
// definitions must already be loaded (typically in BootConfigU at startup).
function ActiveRecord(
  const ADefaultConnectionDefName: string): TMVCEndpointFilter;

// -------------------------------------------------------------------------
// HTTPFilter helpers (engine-wide, attached via lEngine.UseHTTPFilter).
// -------------------------------------------------------------------------

// HTTPFilter that serves static files from ARootFolder under APrefix.
// Requests matching the prefix and pointing to an existing file short-
// circuit with the file contents; everything else falls through to Next()
// (route matching + handlers).
// Path traversal is rejected (any '..' or absolute paths return 403).
// MIME type is inferred from the file extension; unknown types fall back
// to application/octet-stream.
//
//   lEngine.UseHTTPFilter(StaticFiles('/static', 'www'));
function StaticFiles(const APrefix: string; const ARootFolder: string;
  const ADefaultDocument: string = 'index.html'): TMVCHTTPFilter;

// HTTPFilter that compresses the response body post-Next when:
//   - response has a ContentStream larger than ACompressionThreshold bytes;
//   - client advertised a supported encoding via Accept-Encoding (gzip or
//     deflate; gzip wins if both are listed).
// Sets Content-Encoding accordingly. No-op for responses below threshold,
// responses without a ContentStream, or requests without Accept-Encoding.
//
//   lEngine.UseHTTPFilter(Compression(1024));
function Compression(const ACompressionThreshold: Integer = 1024): TMVCHTTPFilter;

// HTTPFilter that adds RFC 7232 ETag validation post-Next:
//   - SHA1-hashes the response ContentStream and stamps a strong ETag
//     header on the response (quoted hex digest);
//   - if the request carries If-None-Match matching the computed ETag,
//     short-circuits the body and returns 304 Not Modified.
// No-op for responses without a ContentStream or with a non-2xx status.
// Register BEFORE Compression so ETag wraps it on the outside — that way
// the post-Next of ETag runs AFTER Compression has rewritten the stream,
// and the hash reflects the bytes actually sent on the wire (different
// ETag per encoding, per RFC).
//
//   lEngine.UseHTTPFilter(ETag).UseHTTPFilter(Compression);
function ETag: TMVCHTTPFilter;

// HTTPFilter that short-circuits requests from any client IP in the
// blocklist with HTTP 403. Comparison is exact-string against
// Ctx.Request.ClientIp; no CIDR matching. Returns the filter as-is so
// callers can chain registration.
//
//   lEngine.UseHTTPFilter(IPBlock(['10.0.0.5', '192.168.1.42']));
function IPBlock(const ABlockedIPs: TArray<string>): TMVCHTTPFilter;

// HTTPFilter that enforces a sliding-window rate limit per client IP.
// More than AMaxRequests within AWindowSeconds triggers HTTP 429 with a
// Retry-After header. State is held in a process-wide thread-safe map.
//
//   lEngine.UseHTTPFilter(RateLimit(100, 60));   // 100 req / minute / IP
function RateLimit(const AMaxRequests: Integer = 60;
  const AWindowSeconds: Integer = 60): TMVCHTTPFilter;

// HTTPFilter that emits a one-line request log via MVCFramework.Logger
// after the inner pipeline completes. Format:
//   [HTTP] <ip> <method> <path> -> <status> (<duration_ms>ms)
// Times include any HTTPFilter wrapped inside it; place this filter
// outermost (first registered) to capture full request latency.
//
//   lEngine.UseHTTPFilter(RequestLog);
function RequestLog: TMVCHTTPFilter;

// HTTPFilter version of CORS. Short-circuits OPTIONS preflight requests
// with the full CORS header set + 200 OK; on every other request stamps
// the simple CORS headers post-Next so they land on success AND error
// responses. Equivalent to the EndpointFilter CORS() helper but engine-
// wide and runs BEFORE routing — important for preflights that should
// not be subject to per-group filters or route matching.
//
//   lEngine.UseHTTPFilter(CORSFilter('*', False, '', 'Content-Type,Authorization',
//     'GET,POST,PUT,DELETE,OPTIONS', 1728000));
function CORSFilter(
  const AAllowedOriginURLs: string = '*';
  const AAllowsCredentials: Boolean = False;
  const AExposeHeaders: string = '';
  const AAllowsHeaders: string = 'Content-Type,Authorization';
  const AAllowsMethods: string = 'GET,POST,PUT,DELETE,PATCH,OPTIONS';
  const AAccessControlMaxAge: Integer = 1728000): TMVCHTTPFilter;

implementation

uses
  System.Diagnostics,
  System.StrUtils,
  System.SyncObjs,
  System.IOUtils,                   // TPath, TFile (StaticFiles HTTPFilter)
  System.ZLib,                      // TZCompressionStream (Compression HTTPFilter)
  System.Hash,                      // THashSHA1 (ETag HTTPFilter)
  System.DateUtils,                 // IncSecond (RateLimit HTTPFilter)
  MVCFramework.Logger,              // LogI (RequestLog HTTPFilter)
  MVCFramework.Router,
  MVCFramework.Rtti.Utils,
  MVCFramework.Serializer.Commons,
  MVCFramework.Serializer.Intf,
  MVCFramework.Serializer.JsonDataObjects,
  MVCFramework.Session,
  MVCFramework.Validation,
  MVCFramework.ValidationEngine,
  MVCFramework.ActiveRecord,        // ActiveRecordConnectionsRegistry (ActiveRecord filter)
  FireDAC.Comp.Client;              // FDManager (ActiveRecord filter)

type
  // Holds the lifetime of a session factory for the MemorySession filter.
  // The filter closure captures an ISessionFactoryHolder reference; when the
  // closure is released (filter dropped at engine shutdown), the interface's
  // refcount drops to zero and the destructor frees the underlying factory.
  ISessionFactoryHolder = interface
    ['{8A0E3CD2-9F7B-4F9E-9E61-2D5B3D0B4B41}']
    function Factory: TMVCWebSessionFactory;
  end;

  TSessionFactoryHolder = class(TInterfacedObject, ISessionFactoryHolder)
  strict private
    fFactory: TMVCWebSessionFactory;
  public
    constructor Create(AFactory: TMVCWebSessionFactory);
    destructor Destroy; override;
    function Factory: TMVCWebSessionFactory;
  end;

constructor TSessionFactoryHolder.Create(AFactory: TMVCWebSessionFactory);
begin
  inherited Create;
  fFactory := AFactory;
end;

destructor TSessionFactoryHolder.Destroy;
begin
  fFactory.Free;
  inherited;
end;

function TSessionFactoryHolder.Factory: TMVCWebSessionFactory;
begin
  Result := fFactory;
end;

threadvar
  GCurrentContext: TWebContext;
  // Per-request renderer published by the dispatcher. RenderView /
  // RenderViews need an Engine + Context + view engine class to do their job;
  // the renderer carries all three. nil outside a minimal-API request scope.
  GCurrentMinimalRenderer: TMVCMinimalRenderer;

function ViewData: TMVCViewDataObject;
begin
  if GCurrentContext = nil then
    raise EMVCMinimalAPI.Create(
      'ViewData called outside a minimal-API request scope');
  Result := GCurrentContext.ViewData;
end;

function CurrentMinimalRendererOrFail: TMVCMinimalRenderer;
begin
  if GCurrentMinimalRenderer = nil then
    raise EMVCMinimalAPI.Create(
      'RenderView/RenderViews called outside a minimal-API request scope');
  Result := GCurrentMinimalRenderer;
end;

function BuildHTMLResponse(const AHtml: string): IMVCResponse;
var
  lResp: TMVCHTMLResponse;
begin
  lResp := TMVCHTMLResponse.Create;
  // StatusCode defaults to 200; caller can override via Result.StatusCode := N
  // after RenderView returns.
  lResp.StatusCode := http_status.OK;
  lResp.HTMLBody := AHtml;
  Result := lResp; // IMVCResponse holds the reference; ARC manages lifetime.
end;

function RenderView(const AViewName: string): IMVCResponse;
begin
  Result := RenderView(AViewName, nil);
end;

function RenderView(const AViewName: string;
  const AOnBeforeRender: TMVCSSVBeforeRenderCallback): IMVCResponse;
var
  lRenderer: TMVCMinimalRenderer;
  lHtml: string;
begin
  lRenderer := CurrentMinimalRendererOrFail;
  lHtml := lRenderer.RenderView(AViewName, AOnBeforeRender);
  Result := BuildHTMLResponse(lHtml);
end;

function RenderViews(const AViewNames: TArray<string>;
  const AUseCommonHeadersAndFooters: Boolean): IMVCResponse;
var
  lRenderer: TMVCMinimalRenderer;
  lHtml: string;
begin
  // AUseCommonHeadersAndFooters is accepted for API parity with
  // TMVCController.RenderViews but ignored — minimal-API handlers have no
  // per-handler page-header/footer state to wrap views with.
  lRenderer := CurrentMinimalRendererOrFail;
  lHtml := lRenderer.RenderViews(AViewNames, AUseCommonHeadersAndFooters);
  Result := BuildHTMLResponse(lHtml);
end;

function MemorySession(const ATimeoutInMinutes: Integer;
  const AHttpOnly: Boolean): TMVCEndpointFilter;
var
  lHolder: ISessionFactoryHolder;
begin
  // Allocate the factory and wrap it in an interface-managed holder. The
  // closure below captures `lHolder` (an interface), so the holder's lifetime
  // follows the closure's: when the filter is dropped (engine shutdown) the
  // closure is freed, the captured interface refcount drops to zero, and the
  // holder's destructor frees the factory.
  lHolder := TSessionFactoryHolder.Create(
    TMVCWebSessionMemoryFactory.Create(AHttpOnly, ATimeoutInMinutes));
  Result :=
    function (const AContext: TWebContext;
              const ANext: TMVCEndpointFilterNext): IMVCResponse
    begin
      AContext.SetSessionFactory(lHolder.Factory);
      Result := ANext();
    end;
end;

{ -------------------------------------------------------------------------- }
{ Native filter implementations: Compression / CORS / JWT / ActiveRecord     }
{ -------------------------------------------------------------------------- }

// --- ActiveRecord ---------------------------------------------------------

var
  // Single-shot guard for FDConnectionDefs.ini load. Equivalent to the
  // gCONNECTION_DEF_FILE_LOADED flag in the classic middleware: the file
  // is parsed once per process, not on every filter construction.
  gMinimalARConnDefFileLoaded: Integer = 0;

function ActiveRecord(
  const ADefaultConnectionDefName: string): TMVCEndpointFilter;
const
  cConnectionDefFileName = 'FDConnectionDefs.ini';
var
  lInitLock: TObject;
  lInitialized: Boolean;
begin
  lInitLock := TObject.Create;
  lInitialized := False;
  Result :=
    function (const AContext: TWebContext;
              const ANext: TMVCEndpointFilterNext): IMVCResponse
    begin
      // Lazy connection-definitions load (idempotent across filter instances).
      if not lInitialized then
      begin
        TMonitor.Enter(lInitLock);
        try
          if not lInitialized then
          begin
            if TInterlocked.CompareExchange(gMinimalARConnDefFileLoaded, 1, 0) = 0 then
            begin
              FDManager.ConnectionDefFileAutoLoad := False;
              FDManager.ConnectionDefFileName := cConnectionDefFileName;
              if not FDManager.ConnectionDefFileLoaded then
                FDManager.LoadConnectionDefFile;
              if (ADefaultConnectionDefName <> '')
                and (not FDManager.IsConnectionDef(ADefaultConnectionDefName)) then
                raise EMVCConfigException.CreateFmt(
                  'ConnectionDefName "%s" not found in config file "%s" - or config file not present',
                  [ADefaultConnectionDefName, FDManager.ActualConnectionDefFileName]);
            end;
            lInitialized := True;
          end;
        finally
          TMonitor.Exit(lInitLock);
        end;
      end;

      // Acquire connection BEFORE Next(), release inside try..finally so the
      // connection is returned to the pool even if the handler raises. The
      // classic IMVCMiddleware OnBeforeRouting/OnAfterRouting hooks can't
      // express this — an exception in the handler skips OnAfterRouting and
      // leaks the connection.
      if ADefaultConnectionDefName <> '' then
        ActiveRecordConnectionsRegistry.AddDefaultConnection(ADefaultConnectionDefName);
      try
        Result := ANext();
      finally
        if ADefaultConnectionDefName <> '' then
          ActiveRecordConnectionsRegistry.RemoveDefaultConnection(False);
      end;
    end;
end;

// --- StaticFiles HTTPFilter ----------------------------------------------

function DetectStaticMimeType(const AFile: string): string;
var
  lExt: string;
begin
  lExt := ExtractFileExt(AFile).ToLower;
  if (lExt = '.html') or (lExt = '.htm') then Exit('text/html; charset=utf-8');
  if lExt = '.css'  then Exit('text/css; charset=utf-8');
  if lExt = '.js'   then Exit('application/javascript; charset=utf-8');
  if lExt = '.json' then Exit('application/json; charset=utf-8');
  if lExt = '.svg'  then Exit('image/svg+xml');
  if lExt = '.png'  then Exit('image/png');
  if (lExt = '.jpg') or (lExt = '.jpeg') then Exit('image/jpeg');
  if lExt = '.gif'  then Exit('image/gif');
  if lExt = '.webp' then Exit('image/webp');
  if lExt = '.ico'  then Exit('image/x-icon');
  if lExt = '.woff' then Exit('font/woff');
  if lExt = '.woff2' then Exit('font/woff2');
  if lExt = '.ttf'  then Exit('font/ttf');
  if lExt = '.pdf'  then Exit('application/pdf');
  if lExt = '.txt'  then Exit('text/plain; charset=utf-8');
  if lExt = '.xml'  then Exit('application/xml');
  Result := 'application/octet-stream';
end;

function StaticFiles(const APrefix: string; const ARootFolder: string;
  const ADefaultDocument: string): TMVCHTTPFilter;
begin
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lPath, lSuffix, lFile, lAbsRoot, lAbsFile, lMime: string;
      lStream: TFileStream;
    begin
      lPath := AContext.Request.PathInfo;

      // Only act on requests inside the prefix. Exact match or sub-path.
      if (lPath <> APrefix) and (not lPath.StartsWith(APrefix + '/')) then
      begin
        ANext();
        Exit;
      end;

      lSuffix := Copy(lPath, Length(APrefix) + 1, MaxInt).TrimLeft(['/']);

      // Default document for directory-style requests (e.g. /static -> /static/index.html).
      if (lSuffix = '') and (ADefaultDocument <> '') then
        lSuffix := ADefaultDocument;

      // Reject path traversal up front. The canonicalization check below is
      // the real defense, but rejecting obvious patterns lets us return 403
      // without touching the filesystem.
      if lSuffix.Contains('..') or (Pos(':', lSuffix) > 0) then
      begin
        AContext.Response.StatusCode := 403;
        Exit;
      end;

      lFile := TPath.Combine(ARootFolder, lSuffix.Replace('/', PathDelim));

      // Canonicalize and ensure the file stays inside the root folder.
      // GetFullPath collapses '..' segments; if the result escapes the root,
      // the request is rejected.
      lAbsRoot := IncludeTrailingPathDelimiter(TPath.GetFullPath(ARootFolder));
      lAbsFile := TPath.GetFullPath(lFile);
      if not lAbsFile.StartsWith(lAbsRoot, True) then
      begin
        AContext.Response.StatusCode := 403;
        Exit;
      end;

      if not TFile.Exists(lAbsFile) then
      begin
        // File doesn't exist under our prefix. Let routing try to match —
        // there may be a lambda handler for the same path. If nothing
        // matches the request will end as a 404 anyway.
        ANext();
        Exit;
      end;

      lMime := DetectStaticMimeType(lAbsFile);
      lStream := TFileStream.Create(lAbsFile, fmOpenRead or fmShareDenyWrite);
      AContext.Response.StatusCode := 200;
      AContext.Response.SetContentStream(lStream, lMime);
      // No ANext() — short-circuit: routing / handlers don't run for this request.
    end;
end;

// --- Compression ----------------------------------------------------------

// Picks the first supported encoding from a comma-separated Accept-Encoding
// header. Returns ctGZIP, ctDeflate, or ctNone. gzip wins if both are listed
// because every modern client supports it and the framing is unambiguous.
function PickCompressionEncoding(const AAcceptEncoding: string): TMVCCompressionType;
var
  lLower: string;
  lTokens: TArray<string>;
  lToken: string;
begin
  Result := TMVCCompressionType.ctNone;
  if AAcceptEncoding = '' then
    Exit;
  lLower := AAcceptEncoding.Trim.ToLower;
  lTokens := lLower.Split([',']);
  // First pass: prefer gzip (most universally interoperable).
  for lToken in lTokens do
    if lToken.Trim = 'gzip' then
      Exit(TMVCCompressionType.ctGZIP);
  for lToken in lTokens do
    if lToken.Trim = 'deflate' then
      Exit(TMVCCompressionType.ctDeflate);
end;

function Compression(const ACompressionThreshold: Integer): TMVCHTTPFilter;
begin
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lContentStream: TStream;
      lMemStream: TMemoryStream;
      lZStream: TZCompressionStream;
      lEncoding: TMVCCompressionType;
    begin
      // Run the inner pipeline first. Any ContentStream we want to compress
      // is only populated after routing + handler + render have completed.
      ANext();

      // ISAPI: the host process handles compression at a different layer.
      if IsLibrary then
        Exit;

      lContentStream := AContext.Response.ContentStream;
      if (lContentStream = nil) or (lContentStream.Size <= ACompressionThreshold) then
        Exit;

      lEncoding := PickCompressionEncoding(AContext.Request.Headers['Accept-Encoding']);
      if lEncoding = TMVCCompressionType.ctNone then
        Exit;

      // Compress into a fresh memory stream then swap it in. Cannot mutate
      // the original stream in place because TFileStream (e.g. from
      // StaticFiles) is read-only.
      lMemStream := TMemoryStream.Create;
      try
        lZStream := TZCompressionStream.Create(lMemStream,
          TZCompressionLevel.zcMax,
          MVC_COMPRESSION_ZLIB_WINDOW_BITS[lEncoding]);
        try
          lContentStream.Position := 0;
          lZStream.CopyFrom(lContentStream, 0);
        finally
          lZStream.Free;
        end;
      except
        lMemStream.Free;
        raise;
      end;
      lMemStream.Position := 0;
      AContext.Response.InternalSetContentStream(lMemStream, True);
      AContext.Response.ContentEncoding := MVC_COMPRESSION_TYPE_AS_STRING[lEncoding];
    end;
end;

// --- ETag -----------------------------------------------------------------

function ETag: TMVCHTTPFilter;
begin
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lContentStream: TStream;
      lDigest, lQuotedETag, lIfNoneMatch: string;
      lEmpty: TMemoryStream;
    begin
      ANext();

      // Only validate 2xx responses; redirects/errors don't carry a stable
      // representation worth caching.
      if (AContext.Response.StatusCode < 200) or (AContext.Response.StatusCode >= 300) then
        Exit;

      lContentStream := AContext.Response.ContentStream;
      if (lContentStream = nil) or (lContentStream.Size = 0) then
        Exit;

      lContentStream.Position := 0;
      lDigest := THashSHA1.GetHashString(lContentStream);
      lQuotedETag := '"' + lDigest + '"';
      AContext.Response.SetCustomHeader('ETag', lQuotedETag);

      lIfNoneMatch := AContext.Request.Headers['If-None-Match'];
      if lIfNoneMatch = '' then
        Exit;

      // Compare allowing the optional weak prefix "W/" that some clients
      // send back even for strong ETags. Compare both quoted forms.
      if SameText(lIfNoneMatch, lQuotedETag) or SameText(lIfNoneMatch, 'W/' + lQuotedETag) then
      begin
        // 304 Not Modified: empty body, keep the ETag header on the way out.
        lEmpty := TMemoryStream.Create;
        AContext.Response.InternalSetContentStream(lEmpty, True);
        AContext.Response.StatusCode := 304;
      end;
    end;
end;

// --- IPBlock --------------------------------------------------------------

function IPBlock(const ABlockedIPs: TArray<string>): TMVCHTTPFilter;
var
  lBlocked: TArray<string>;
begin
  // Copy the array into a local variable so the closure captures a snapshot,
  // not the caller's mutable storage. Cheap and small (IP lists are tiny).
  lBlocked := Copy(ABlockedIPs);
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lIP, lBan: string;
    begin
      lIP := AContext.Request.ClientIp;
      for lBan in lBlocked do
        if SameText(lIP, lBan) then
        begin
          AContext.Response.StatusCode := 403;
          Exit; // no Next() — short-circuit
        end;
      ANext();
    end;
end;

// --- RateLimit ------------------------------------------------------------

type
  // Holds the timestamp queue for one client IP. Wrapped in a class because
  // we store it in a generic TDictionary that owns its values.
  TIPHits = class
  public
    Hits: TList<TDateTime>;
    constructor Create;
    destructor Destroy; override;
  end;

constructor TIPHits.Create;
begin
  inherited Create;
  Hits := TList<TDateTime>.Create;
end;

destructor TIPHits.Destroy;
begin
  Hits.Free;
  inherited;
end;

function RateLimit(const AMaxRequests: Integer;
  const AWindowSeconds: Integer): TMVCHTTPFilter;
var
  lState: TObjectDictionary<string, TIPHits>;
  lLock: TObject;
begin
  // Process-wide state — one map per RateLimit() filter instance, shared by
  // every request that hits this filter. Lock guards both the dictionary
  // and each TIPHits.Hits list (cheap, low contention for typical loads).
  lState := TObjectDictionary<string, TIPHits>.Create([doOwnsValues]);
  lLock := TObject.Create;

  // Closure owns lState + lLock for the engine's lifetime. They leak at
  // process exit which is acceptable for a server's main engine — there is
  // no Dispose() hook on TMVCHTTPFilter, by design (HTTPFilters are
  // closures, not components).

  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lIP: string;
      lEntry: TIPHits;
      lNow, lCutoff: TDateTime;
      i: Integer;
    begin
      lIP := AContext.Request.ClientIp;
      lNow := Now;
      lCutoff := IncSecond(lNow, -AWindowSeconds);

      TMonitor.Enter(lLock);
      try
        if not lState.TryGetValue(lIP, lEntry) then
        begin
          lEntry := TIPHits.Create;
          lState.Add(lIP, lEntry);
        end;
        // Drop timestamps that fell out of the window.
        i := 0;
        while (i < lEntry.Hits.Count) and (lEntry.Hits[i] < lCutoff) do
          Inc(i);
        if i > 0 then
          lEntry.Hits.DeleteRange(0, i);

        if lEntry.Hits.Count >= AMaxRequests then
        begin
          AContext.Response.SetCustomHeader('Retry-After', IntToStr(AWindowSeconds));
          AContext.Response.StatusCode := 429;
          Exit; // short-circuit
        end;
        lEntry.Hits.Add(lNow);
      finally
        TMonitor.Exit(lLock);
      end;

      ANext();
    end;
end;

// --- RequestLog -----------------------------------------------------------

function RequestLog: TMVCHTTPFilter;
begin
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    var
      lStart: TStopwatch;
    begin
      lStart := TStopwatch.StartNew;
      try
        ANext();
      finally
        lStart.Stop;
        LogI(Format('[HTTP] %s %s %s -> %d (%dms)', [
          AContext.Request.ClientIp,
          GetEnumName(TypeInfo(TMVCHTTPMethodType), Ord(AContext.Request.HTTPMethod)),
          AContext.Request.PathInfo,
          AContext.Response.StatusCode,
          lStart.ElapsedMilliseconds]));
      end;
    end;
end;

// --- CORS (HTTPFilter version) --------------------------------------------

// Forward — defined later under "CORS (EndpointFilter)" because the
// original classic CORS() helper also calls it. Single source of truth.
procedure StampSimpleCORSHeaders(const AContext: TWebContext;
  const AAllowedOriginURLs: string;
  const AAllowsCredentials: Boolean;
  const AExposeHeaders: string); forward;

function CORSFilter(
  const AAllowedOriginURLs: string;
  const AAllowsCredentials: Boolean;
  const AExposeHeaders: string;
  const AAllowsHeaders: string;
  const AAllowsMethods: string;
  const AAccessControlMaxAge: Integer): TMVCHTTPFilter;
begin
  Result :=
    procedure (const AContext: TWebContext;
               const ANext: TMVCHTTPFilterNext)
    begin
      // Preflight: short-circuit OPTIONS with the full CORS header set +
      // 200 OK and empty body. Routing/handlers never run — important for
      // OPTIONS to a path with no matching route (would otherwise 404).
      if AContext.Request.HTTPMethod = httpOPTIONS then
      begin
        StampSimpleCORSHeaders(AContext,
          AAllowedOriginURLs, AAllowsCredentials, AExposeHeaders);
        AContext.Response.SetCustomHeader('Access-Control-Allow-Methods', AAllowsMethods);
        AContext.Response.SetCustomHeader('Access-Control-Allow-Headers', AAllowsHeaders);
        AContext.Response.SetCustomHeader('Access-Control-Max-Age', IntToStr(AAccessControlMaxAge));
        AContext.Response.StatusCode := 200;
        Exit; // no Next() — short-circuit
      end;

      // Non-preflight: forward, then stamp the simple headers in a
      // try..finally so they land on success AND on exception-derived
      // 500 responses (browser still needs CORS headers to surface the
      // error to the page).
      try
        ANext();
      finally
        StampSimpleCORSHeaders(AContext,
          AAllowedOriginURLs, AAllowsCredentials, AExposeHeaders);
      end;
    end;
end;

// --- CORS (EndpointFilter) ------------------------------------------------

// Stamps the "simple" CORS response headers (origin, credentials, expose).
// Extracted to a module-level proc because anonymous methods cannot capture
// nested procedures (E2555). The closure inside CORS() calls it twice — for
// the preflight branch and the post-handler branch.
procedure StampSimpleCORSHeaders(const AContext: TWebContext;
  const AAllowedOriginURLs: string;
  const AAllowsCredentials: Boolean;
  const AExposeHeaders: string);
begin
  AContext.Response.SetCustomHeader('Access-Control-Allow-Origin', AAllowedOriginURLs);
  if AAllowsCredentials then
    AContext.Response.SetCustomHeader('Access-Control-Allow-Credentials', 'true');
  if AExposeHeaders <> '' then
    AContext.Response.SetCustomHeader('Access-Control-Expose-Headers', AExposeHeaders);
end;

function CORS(
  const AAllowedOriginURLs: string;
  const AAllowsCredentials: Boolean;
  const AExposeHeaders: string;
  const AAllowsHeaders: string;
  const AAllowsMethods: string;
  const AAccessControlMaxAge: Integer): TMVCEndpointFilter;
begin
  Result :=
    function (const AContext: TWebContext;
              const ANext: TMVCEndpointFilterNext): IMVCResponse
    var
      lResp: TMVCResponse;
    begin
      // Preflight: short-circuit OPTIONS with the full CORS header set,
      // 200 OK, empty body. The handler never runs.
      if AContext.Request.HTTPMethod = httpOPTIONS then
      begin
        StampSimpleCORSHeaders(AContext,
          AAllowedOriginURLs, AAllowsCredentials, AExposeHeaders);
        AContext.Response.SetCustomHeader('Access-Control-Allow-Methods', AAllowsMethods);
        AContext.Response.SetCustomHeader('Access-Control-Allow-Headers', AAllowsHeaders);
        AContext.Response.SetCustomHeader('Access-Control-Max-Age', IntToStr(AAccessControlMaxAge));
        lResp := TMVCResponse.Create;
        lResp.StatusCode := http_status.OK;
        Exit(lResp);
      end;

      // Non-preflight: forward, then stamp the simple CORS headers on the
      // response. Use a try..finally so headers are stamped even if the
      // handler raises (the framework's exception handler still writes a
      // response — we want the browser to see CORS headers on the 500).
      try
        Result := ANext();
      finally
        StampSimpleCORSHeaders(AContext,
          AAllowedOriginURLs, AAllowsCredentials, AExposeHeaders);
      end;
    end;
end;

// --- JWT ------------------------------------------------------------------

// Module-level helper extracted from JWT() so the closure can call it
// (anonymous methods cannot capture nested procedures — E2555).
function BuildJWTLoginResponse(const AContext: TWebContext;
  const ARolesList: TList<string>;
  const ASessionData: TDictionary<string, string>;
  const AClaimsSetup: TJWTClaimsSetup;
  const ASecret, AHMACAlgorithm: string;
  const ALeewaySeconds: Cardinal): IMVCResponse;
var
  lJWT: TJWT;
  lToken: string;
  lResp: TMVCResponse;
  lKey: string;
begin
  lJWT := TJWT.Create(ASecret, ALeewaySeconds);
  try
    lJWT.HMACAlgorithm := AHMACAlgorithm;
    // Apply caller-provided baseline claims (issuer, audience, expiry).
    if Assigned(AClaimsSetup) then
      AClaimsSetup(lJWT);
    // Custom claims: roles + session data set by the auth handler.
    for lKey in ARolesList do
      lJWT.CustomClaims.Items['roles'] := lKey;
    if Assigned(ASessionData) then
      for lKey in ASessionData.Keys do
        lJWT.CustomClaims.Items[lKey] := ASessionData[lKey];
    lToken := lJWT.GetToken;
  finally
    lJWT.Free;
  end;
  lResp := TMVCResponse.Create;
  lResp.StatusCode := http_status.OK;
  AContext.Response.SetCustomHeader('Authorization', 'bearer ' + lToken);
  Result := lResp;
end;

function JWT(
  const AAuthenticationHandler: IMVCAuthenticationHandler;
  const AClaimsSetup: TJWTClaimsSetup;
  const ASecret: string;
  const ALoginURLSegment: string;
  const AClaimsToCheck: TJWTCheckableClaims;
  const ALeewaySeconds: Cardinal;
  const AHMACAlgorithm: string): TMVCEndpointFilter;
const
  cAuthHeader      = 'Authorization';
  cBearerPrefix    = 'bearer ';
  cUserNameHeader  = 'jwtusername';
  cPasswordHeader  = 'jwtpassword';
begin
  Result :=
    function (const AContext: TWebContext;
              const ANext: TMVCEndpointFilterNext): IMVCResponse
    var
      lAuthHeader, lToken, lError: string;
      lJWT: TJWT;
      lAccepted: Boolean;
      lRoles: TList<string>;
      lSession: TSessionData;
      lUserName, lPassword: string;
    begin
      // Login endpoint: special-case credential exchange -> token.
      // POST /login with jwtusername + jwtpassword headers returns a token.
      if SameText(AContext.Request.PathInfo, ALoginURLSegment)
        and (AContext.Request.HTTPMethod = httpPOST) then
      begin
        lUserName := AContext.Request.Headers[cUserNameHeader];
        lPassword := AContext.Request.Headers[cPasswordHeader];
        if (lUserName = '') or (lPassword = '') then
          Exit(Status(http_status.Unauthorized, 'Missing credentials'));
        lRoles := TList<string>.Create;
        lSession := TSessionData.Create;
        try
          lAccepted := False;
          AAuthenticationHandler.OnAuthentication(AContext,
            lUserName, lPassword, lRoles, lAccepted, lSession);
          if not lAccepted then
            Exit(Status(http_status.Unauthorized, 'Invalid credentials'));
          Result := BuildJWTLoginResponse(AContext, lRoles, lSession,
            AClaimsSetup, ASecret, AHMACAlgorithm, ALeewaySeconds);
        finally
          lRoles.Free;
          lSession.Free;
        end;
        Exit;
      end;

      // All other endpoints: require a valid bearer token.
      lAuthHeader := AContext.Request.Headers[cAuthHeader];
      if not lAuthHeader.ToLower.StartsWith(cBearerPrefix) then
        Exit(Status(http_status.Unauthorized, 'Missing or malformed bearer token'));
      lToken := Copy(lAuthHeader, Length(cBearerPrefix) + 1, MaxInt).Trim;

      lJWT := TJWT.Create(ASecret, ALeewaySeconds);
      try
        lJWT.HMACAlgorithm := AHMACAlgorithm;
        lJWT.RegClaimsToChecks := AClaimsToCheck;
        if not lJWT.LoadToken(lToken, lError) then
          Exit(Status(http_status.Unauthorized, 'Invalid token: ' + lError));
        // Make claims available to the handler via the framework's
        // LoggedUser slot — same surface controller-based apps use.
        AContext.LoggedUser.UserName := lJWT.Claims.Subject;
        AContext.LoggedUser.LoggedSince := lJWT.Claims.IssuedAt;
        AContext.LoggedUser.CustomData := nil;
      finally
        lJWT.Free;
      end;

      Result := ANext();
    end;
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalRenderer                                                        }
{ -------------------------------------------------------------------------- }

type
  // "Cracker" used solely to assign FBeforeRenderCallback on a view engine
  // instance from this unit. TMVCBaseViewEngine declares the field as
  // protected; same-class access from a different unit requires reopening
  // the class via inheritance to surface the protected member. The classic
  // TMVCController.GetRenderedView (same unit as TMVCBaseViewEngine) sets it
  // directly — we replicate that exact behaviour here.
  TMVCBaseViewEngineAccess = class(TMVCBaseViewEngine);

function TMVCMinimalRenderer.RenderView(const AViewName: string;
  const AOnBeforeRender: TMVCSSVBeforeRenderCallback): string;
var
  lView: TMVCBaseViewEngine;
  lStrStream: TStringBuilder;
begin
  // Mirrors TMVCController.GetRenderedView, but without a TMVCController
  // instance: the data source is TWebContext.ViewData (populated by the
  // global ViewData() helper) instead of FViewModel, and the controller
  // argument to the view-engine constructor is nil. FController is set on
  // TMVCBaseViewEngine but the framework never reads it back, so passing nil
  // is safe for the bundled engines (TemplatePro / WebStencils / Mustache).
  lStrStream := TStringBuilder.Create;
  try
    lView := Engine.ViewEngineClass.Create(
      Engine, GetContext, nil, GetContext.ViewData, ContentType);
    try
      TMVCBaseViewEngineAccess(lView).FBeforeRenderCallback := AOnBeforeRender;
      lView.Execute(AViewName, lStrStream);
    finally
      lView.Free;
    end;
    Result := lStrStream.ToString;
  finally
    lStrStream.Free;
  end;
end;

function TMVCMinimalRenderer.RenderViews(const AViewNames: TArray<string>;
  const AUseCommonHeadersAndFooters: Boolean): string;
var
  lView: TMVCBaseViewEngine;
  lViewName: string;
  lStrStream: TStringBuilder;
begin
  // AUseCommonHeadersAndFooters is accepted for API parity with
  // TMVCController.RenderViews but ignored — minimal-API handlers have no
  // per-handler page-header/footer state to wrap views with.
  //
  // Mirrors TMVCController.GetRenderedView, but without a TMVCController
  // instance: the data source is TWebContext.ViewData (populated by the
  // global ViewData() helper) instead of FViewModel, and the controller
  // argument to the view-engine constructor is nil. FController is set on
  // TMVCBaseViewEngine but the framework never reads it back, so passing nil
  // is safe for the bundled engines (TemplatePro / WebStencils / Mustache).
  lStrStream := TStringBuilder.Create;
  try
    lView := Engine.ViewEngineClass.Create(
      Engine, GetContext, nil, GetContext.ViewData, ContentType);
    try
      for lViewName in AViewNames do
      begin
        lView.Execute(lViewName, lStrStream);
      end;
    finally
      lView.Free;
    end;
    Result := lStrStream.ToString;
  finally
    lStrStream.Free;
  end;
end;

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

procedure TMVCMinimalRoute.SetName(const AValue: string);
var
  lOther: TMVCMinimalRoute;
begin
  if AValue = '' then
    raise EMVCMinimalAPI.Create(http_status.InternalServerError,
      'WithName: route name cannot be empty.');
  if fRegistry <> nil then
    for lOther in TMVCMinimalRegistry(fRegistry).AllRoutes do
      if (lOther <> Self) and SameText(lOther.Name, AValue) then
        raise EMVCMinimalAPI.CreateFmt(http_status.InternalServerError,
          'WithName: duplicate route name "%s" (already used by %s %s). ' +
          'Operation names must be unique across the engine.',
          [AValue, GetEnumName(TypeInfo(TMVCHTTPMethodType), Ord(lOther.Verb)),
           lOther.PathPattern]);
  fName := AValue;
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

function TMVCRouteHandle.WithSummary(const ASummary: string): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('summary', TValue.From<string>(ASummary));
  Result := Self;
end;

function TMVCRouteHandle.WithDescription(const ADescription: string): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('description', TValue.From<string>(ADescription));
  Result := Self;
end;

function TMVCRouteHandle.WithTags(const ATag: string): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('tags', TValue.From<TArray<string>>([ATag]));
  Result := Self;
end;

function TMVCRouteHandle.WithTags(const ATags: TArray<string>): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('tags', TValue.From<TArray<string>>(ATags));
  Result := Self;
end;

function TMVCRouteHandle.WithDeprecated(const AValue: Boolean): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('deprecated', TValue.From<Boolean>(AValue));
  Result := Self;
end;

function TMVCRouteHandle.Produces<T>: TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('produces.200',
    TValue.From<PTypeInfo>(TypeInfo(T)));
  Result := Self;
end;

function TMVCRouteHandle.WithOpenAPI(const AVisible: Boolean): TMVCRouteHandle;
begin
  fRoute.Metadata.AddOrSetValue('openapi.visible', TValue.From<Boolean>(AVisible));
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
{ TMVCMinimalRouteHelper                                                     }
{ -------------------------------------------------------------------------- }

class function TMVCMinimalRouteHelper.IsVisibleInOpenAPI(
  const ARoute: TMVCMinimalRoute): Boolean;
var
  lVisible: TValue;
begin
  if ARoute.Metadata.TryGetValue('openapi.visible', lVisible)
    and not lVisible.IsEmpty then
    Result := lVisible.AsBoolean
  else
    Result := ARoute.RouteKind = rkApi;
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
  Result.fRegistry := Self;
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

function TMVCMinimalRegistry.AllRoutes: TArray<TMVCMinimalRoute>;
var
  I: Integer;
begin
  SetLength(Result, fRoutes.Count);
  for I := 0 to fRoutes.Count - 1 do
    Result[I] := fRoutes[I];
end;

procedure TMVCMinimalRegistry.AddHTTPFilter(const AFilter: TMVCHTTPFilter);
begin
  fHTTPFilters := fHTTPFilters + [AFilter];
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

// Score a route candidate against the request's Accept and Content-Type.
// rkWeb prefers HTML responses and form/multipart bodies.
// rkApi prefers JSON responses and JSON bodies.
function ScoreRouteForNegotiation(AKind: TMVCRouteKind;
  const AAcceptLower, AContentTypeLower: string): Integer;
begin
  Result := 0;
  case AKind of
    rkWeb:
      begin
        if Pos('text/html', AAcceptLower) > 0 then Inc(Result, 10);
        if Pos('application/x-www-form-urlencoded', AContentTypeLower) > 0 then
          Inc(Result, 5);
        if Pos('multipart/form-data', AContentTypeLower) > 0 then Inc(Result, 5);
      end;
    rkApi:
      begin
        if Pos('application/json', AAcceptLower) > 0 then Inc(Result, 10);
        if Pos('application/json', AContentTypeLower) > 0 then Inc(Result, 5);
      end;
  end;
end;

function TMVCMinimalRegistry.TryMatch(AVerb: TMVCHTTPMethodType;
  const APath: string; const AAcceptHeader: string;
  const AContentTypeHeader: string;
  const AParamsTable: TMVCRequestParamsTable;
  out ARoute: TMVCMinimalRoute): Boolean;
var
  I: Integer;
  lRoute, lBest: TMVCMinimalRoute;
  lCandidates: TArray<TMVCMinimalRoute>;
  lAcceptL, lCtypeL: string;
  lBestScore, lScore: Integer;
begin
  Result := False;
  ARoute := nil;

  // Pass 1: collect every route that matches the verb + path.
  for I := 0 to fRoutes.Count - 1 do
  begin
    lRoute := fRoutes[I];
    if lRoute.Verb <> AVerb then
      Continue;
    AParamsTable.Clear;
    if MatchPath(lRoute.PathPattern, APath, AParamsTable) then
      lCandidates := lCandidates + [lRoute];
  end;

  if Length(lCandidates) = 0 then
  begin
    AParamsTable.Clear;
    Exit;
  end;

  // Single candidate: hot path. Repopulate AParamsTable and return.
  if Length(lCandidates) = 1 then
  begin
    ARoute := lCandidates[0];
    AParamsTable.Clear;
    MatchPath(ARoute.PathPattern, APath, AParamsTable);
    Exit(True);
  end;

  // Multiple candidates → content negotiation. Score each by Accept + Content-Type.
  lAcceptL := LowerCase(AAcceptHeader);
  lCtypeL := LowerCase(AContentTypeHeader);
  lBest := lCandidates[0];
  lBestScore := ScoreRouteForNegotiation(lBest.RouteKind, lAcceptL, lCtypeL);
  for I := 1 to High(lCandidates) do
  begin
    lScore := ScoreRouteForNegotiation(lCandidates[I].RouteKind, lAcceptL, lCtypeL);
    if lScore > lBestScore then
    begin
      lBest := lCandidates[I];
      lBestScore := lScore;
    end;
  end;

  ARoute := lBest;
  AParamsTable.Clear;
  MatchPath(ARoute.PathPattern, APath, AParamsTable);
  Result := True;
end;

{ -------------------------------------------------------------------------- }
{ TMVCMinimalArgResolver — helpers (must be class methods because Resolve<T> }
{ is a generic method declared in interface section)                         }
{ -------------------------------------------------------------------------- }

class function TMVCMinimalArgResolver.ConvertStringTo(const AValue: string;
  ATypeInfo: PTypeInfo): TValue;
begin
  // Shared value coercion (see MVCFramework.Serializer.Commons). The classic
  // controller binder (TMVCEngine.GetActualParam) routes through the same
  // function, so minimal handlers and controller actions bind primitives
  // identically.
  Result := MVCStringToTValue(AValue, ATypeInfo);
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
  lFromContentField: MVCFromContentFieldAttribute;
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
      lFromContentField := nil;

      for lAttr in lField.GetAttributes do
      begin
        if lAttr is MVCFromBodyAttribute then
          lFromBody := MVCFromBodyAttribute(lAttr)
        else if lAttr is MVCFromQueryStringAttribute then
          lFromQuery := MVCFromQueryStringAttribute(lAttr)
        else if lAttr is MVCFromHeaderAttribute then
          lFromHeader := MVCFromHeaderAttribute(lAttr)
        else if lAttr is MVCFromCookieAttribute then
          lFromCookie := MVCFromCookieAttribute(lAttr)
        else if lAttr is MVCFromContentFieldAttribute then
          lFromContentField := MVCFromContentFieldAttribute(lAttr);
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
      end
      else if lFromContentField <> nil then
      begin
        // Mirror the classic controller (MVCFramework.pas) behavior:
        // TArray<string> fields bind to ContentParamsMulti to support
        // multi-value form fields (e.g. <select multiple>, repeated checkboxes).
        // Only TArray<string> is supported for multi-value bind; other dynamic
        // array types raise a clear error rather than producing a TValue cast
        // failure at runtime.
        if SameText(lField.FieldType.QualifiedName, 'System.TArray<System.string>') then
        begin
          lField.SetValue(lAddr,
            TValue.From< TArray<string> >(
              AContext.Request.ContentParamsMulti[lFromContentField.ParamName]));
        end
        else if lField.FieldType.QualifiedName.StartsWith('System.TArray<System.', True) then
        begin
          raise EMVCMinimalAPI.CreateFmt(http_status.InternalServerError,
            '[MVCFromContentField] on record field "%s" supports only TArray<string> for multi-value bind. ' +
            'Field type "%s" is not supported.',
            [lField.Name, lField.FieldType.QualifiedName]);
        end
        else
        begin
          lStrValue := AContext.Request.ContentParam(lFromContentField.ParamName);
          if lStrValue.IsEmpty and lFromContentField.CanBeUsedADefaultValue then
            lStrValue := lFromContentField.DefaultValueAsString;
          lFieldValue := TMVCMinimalArgResolver.ConvertStringTo(lStrValue, lField.FieldType.Handle);
          lField.SetValue(lAddr, lFieldValue);
        end;
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

var
  // Process-wide engine -> middleware map used by GetOrCreateMiddleware so
  // subsequent MapXxx calls append to the SAME middleware's registry. The
  // middleware destructor removes its slot when its engine is freed so a
  // reallocated engine at the same address does not pick up a dangling
  // pointer.
  gMinimalAPIByEngine: TDictionary<Pointer, TMVCMinimalAPIMiddleware> = nil;
  gMinimalAPILock: TObject = nil;

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
  // Drop this engine's slot from the process-wide registry. Otherwise the
  // dangling Pointer(fEngine) lingers and a new engine reallocated at the
  // same address will pick up THIS (freed) middleware on first lookup.
  if Assigned(gMinimalAPILock) and Assigned(gMinimalAPIByEngine) then
  begin
    TMonitor.Enter(gMinimalAPILock);
    try
      gMinimalAPIByEngine.Remove(Pointer(fEngine));
    finally
      TMonitor.Exit(gMinimalAPILock);
    end;
  end;
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
function BuildHTTPFilterChain(
  const AFilters: TArray<TMVCHTTPFilter>;
  const ACtx: TWebContext;
  const ATerminator: TMVCHTTPFilterNext): TMVCHTTPFilterNext;
var
  i: Integer;
  lInner: TMVCHTTPFilterNext;
  lFilter: TMVCHTTPFilter;
begin
  // innermost = the terminator (typically: do the actual minimal-API dispatch)
  lInner := ATerminator;
  // wrap each filter from LAST to FIRST so registration order = outer-to-inner
  // at runtime (first registered fires first pre-Next, last post-Next).
  for i := High(AFilters) downto 0 do
  begin
    lFilter := AFilters[i];
    lInner := (function (const F: TMVCHTTPFilter;
                         const NextRef: TMVCHTTPFilterNext): TMVCHTTPFilterNext
      begin
        Result := procedure
          begin
            F(ACtx, NextRef);
          end;
      end)(lFilter, lInner);
  end;
  Result := lInner;
end;

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
  lFilters: TArray<TMVCHTTPFilter>;
  lNextCalled, lInnerHandled: Boolean;
  lTerminator: TMVCHTTPFilterNext;
begin
  if AHandled then
    Exit;

  lFilters := fRegistry.HTTPFilters;
  if Length(lFilters) = 0 then
  begin
    // No HTTPFilters registered: pass straight to the inner dispatch.
    DoMinimalDispatch(AContext, AHandled);
    Exit;
  end;

  // HTTPFilters wrap the entire inner dispatch. Innermost terminator captures
  // whether Next() was called so we can decide AHandled:
  //   * Next called      -> defer to the inner dispatcher's verdict
  //   * Next NOT called  -> the filter short-circuited (e.g. IP block 403,
  //                          static file served, rate limit 429) - mark as
  //                          handled so the engine stops processing
  lNextCalled := False;
  lInnerHandled := False;
  lTerminator := procedure
    begin
      lNextCalled := True;
      DoMinimalDispatch(AContext, lInnerHandled);
    end;
  BuildHTTPFilterChain(lFilters, AContext, lTerminator)();
  if not lNextCalled then
    AHandled := True
  else
    AHandled := lInnerHandled;
end;

procedure TMVCMinimalAPIMiddleware.DoMinimalDispatch(AContext: TWebContext;
  var AHandled: Boolean);
var
  lRoute: TMVCMinimalRoute;
  lRenderer: TMVCMinimalRenderer;
  lResp: IMVCResponse;
  lParamsTable: TMVCRequestParamsTable;
  lOwnedParamsTable: Boolean;
  lStopWatch: TStopwatch;
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
      AContext.Request.PathInfo,
      AContext.Request.Headers['Accept'],
      AContext.Request.Headers['Content-Type'],
      lParamsTable, lRoute) then
    begin
      // No minimal-API route matched - let the regular controller router proceed.
      Exit;
    end;

    // Wire ParamsTable into the context so the resolver can read segments.
    AContext.ParamsTable := lParamsTable;

    // Match TMVCEngine.HandleRequest semantics: measure the wall-clock time
    // spent dispatching the matched route, then fire the engine's OnRouterLog
    // hook so the default Gin-style console line is emitted for minimal-API
    // routes too. Without this, only controller-based routes get logged and
    // the wizard-generated minimal-API project appears silent on the console.
    lStopWatch := TStopwatch.StartNew;

    lRenderer := TMVCMinimalRenderer.Create;
    try
      lRenderer.Engine := fEngine;
      lRenderer.SetContext(AContext);
      lRenderer.SetContentType(TMVCMediaType.APPLICATION_JSON);
      lRenderer.Route := lRoute;  // <-- gives Resolve<T> access to group data

      // Build the filter chain (filters wrap the handler call). Any
      // try/except/finally semantics belong INSIDE individual filters
      // — there is no separate Before/Success/Error/Always now.
      // The threadvar set/clear wraps the entire filter chain AND the
      // framework-level exception handlers, so global helpers (e.g.
      // RenderView, ViewData) work from any handler or filter, and so
      // future error-page rendering inside the except blocks below can
      // still see the current context/renderer.
      GCurrentContext := AContext;
      GCurrentMinimalRenderer := lRenderer;
      try
        try
          lResp := BuildFilterChain(lRoute, AContext, lRenderer)();
          if lResp <> nil then
            TMVCRenderer.InternalRenderMVCResponse(lRenderer,
              TMVCResponse(lResp as TObject));
        except
          // Validation failures (EMVCValidationException) carry 422 from
          // their constructor and fall through to the EMVCException handler
          // below, which respects the exception's own status. 422
          // (Unprocessable Entity, RFC 4918) is the right code: the request
          // was syntactically well-formed JSON but failed semantic validation
          // — distinct from 400 (Bad Request) used for parse / binding
          // failures (EMVCMinimalAPI).
          on E: EMVCException do
            RenderExceptionAsProblem(lRenderer, AContext,
              E.HTTPStatusCode, ReasonPhraseFor(E.HTTPStatusCode), E);
          on E: Exception do
            RenderExceptionAsProblem(lRenderer, AContext,
              http_status.InternalServerError, 'Internal Server Error', E);
        end;
      finally
        GCurrentMinimalRenderer := nil;
        GCurrentContext := nil;
      end;
      AHandled := True;
    finally
      lRenderer.Route := nil;  // make the dangling-ref window minimal
      lRenderer.Free;
    end;

    if Assigned(fEngine.OnRouterLog) then
    begin
      AContext.Data['__duration'] := Format('%dms', [lStopWatch.ElapsedMilliseconds]);
      fEngine.OnRouterLog(rlsRouteFound, AContext);
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
{ TMVCEngineMinimalAPIHelper                                                 }
{                                                                            }
{ The middleware is added to the engine's middleware list (engine owns the   }
{ interface reference). We also keep a typed pointer in gMinimalAPIByEngine  }
{ so subsequent MapXxx calls append to the SAME middleware's registry        }
{ without relying on interface-to-class cast tricks that are fragile across  }
{ Delphi versions.                                                           }
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

function TMVCEngineMinimalAPIHelper.RegisterFromGroup(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk): TMVCMinimalRoute;
begin
  Result := GetOrCreateMiddleware.Registry.Add(AVerb, APath, AThunk);
end;

function TMVCEngineMinimalAPIHelper.UseHTTPFilter(
  const AFilter: TMVCHTTPFilter): TMVCEngine;
begin
  GetOrCreateMiddleware.Registry.AddHTTPFilter(AFilter);
  Result := Self;
end;

function TMVCEngineMinimalAPIHelper.Root: TMVCRouteGroup<TObject>;
begin
  // Always starts as rkApi. Call .AsWeb on the returned group for HTML routes.
  GetOrCreateMiddleware;
  Result := TMVCRouteGroup<TObject>.Create(Self, '', nil);
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

{ -------------------------------------------------------------------------- }
{ TMVCRouteGroup<T>                                                          }
{ -------------------------------------------------------------------------- }

class function TMVCRouteGroup<T>.Create(AEngine: TMVCEngine;
  const APrefix: string; const AData: T;
  ARouteKind: TMVCRouteKind): TMVCRouteGroup<T>;
begin
  Result.fEngine := AEngine;
  Result.fPrefix := APrefix;
  Result.fData := AData;
  Result.fRouteKind := ARouteKind;
  // hook arrays start nil — TArray refcounted assignment is no-op for nil
end;

function TMVCRouteGroup<T>.RegisterRoute(AVerb: TMVCHTTPMethodType;
  const APath: string; AThunk: TMVCMinimalThunk;
  const AParamTypes: TArray<PTypeInfo>): TMVCMinimalRoute;
begin
  Result := fEngine.RegisterFromGroup(AVerb, fPrefix + APath, AThunk);
  Result.RouteKind := fRouteKind;
  if fData <> nil then
  begin
    Result.GroupData := TObject(fData);
    Result.GroupDataTypeInfo := TypeInfo(T);
  end;
  // copy filter array (TArray = refcount bump, near zero cost)
  Result.Filters := fFilters;
  if Length(AParamTypes) > 0 then
    Result.ParamTypes := AParamTypes;
end;

function TMVCRouteGroup<T>.Prefix(const APath: string): TMVCRouteGroup<T>;
begin
  Result := Self;
  Result.fPrefix := fPrefix + APath;
end;

function TMVCRouteGroup<T>.Prefix<U>(const APath: string; const AData: U;
  AOwns: Boolean): TMVCRouteGroup<U>;
var
  lFilter: TMVCEndpointFilter;
begin
  // Filters propagate across the type boundary: TMVCEndpointFilter is not
  // parametric on T, so the chain carries trivially. Matches the model of
  // ASP.NET Core MapGroup and FastAPI include_router: cross-cutting
  // concerns (logging, auth, rate-limit) added on a parent group are seen
  // by every nested route, regardless of whether the typed data changed.
  // The parent's RouteKind also propagates: a child of an .AsWeb group stays
  // rkWeb, even when the typed data slot changes.
  Result := fEngine.Prefix<U>(fPrefix + APath, AData, AOwns);
  if fRouteKind = rkWeb then
    Result := Result.AsWeb;
  for lFilter in fFilters do
    Result := Result.Use(lFilter);
end;

// ----- endpoint filter ----------------------------------------------------

function TMVCRouteGroup<T>.AsWeb: TMVCRouteGroup<T>;
begin
  Result := Self;
  Result.fRouteKind := rkWeb;
end;

function TMVCRouteGroup<T>.AsApi: TMVCRouteGroup<T>;
begin
  Result := Self;
  Result.fRouteKind := rkApi;
end;

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
  const APath: string; AThunk: TMVCMinimalThunk;
  const AParamTypes: TArray<PTypeInfo>): TMVCRouteHandle;
var
  V: TMVCHTTPMethodType;
  lLast: TMVCMinimalRoute;
begin
  lLast := nil;
  for V in AVerbs do
    lLast := RegisterRoute(V, APath, AThunk, AParamTypes);
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
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make0(AHandler), nil));
end;

function TMVCRouteGroup<T>.MapGet<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]));
end;

function TMVCRouteGroup<T>.MapGet<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpGET, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]));
end;

// POST
function TMVCRouteGroup<T>.MapPost(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make0(AHandler), nil));
end;

function TMVCRouteGroup<T>.MapPost<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]));
end;

function TMVCRouteGroup<T>.MapPost<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPOST, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]));
end;

// PUT
function TMVCRouteGroup<T>.MapPut(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make0(AHandler), nil));
end;

function TMVCRouteGroup<T>.MapPut<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]));
end;

function TMVCRouteGroup<T>.MapPut<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPUT, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]));
end;

// DELETE
function TMVCRouteGroup<T>.MapDelete(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make0(AHandler), nil));
end;

function TMVCRouteGroup<T>.MapDelete<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]));
end;

function TMVCRouteGroup<T>.MapDelete<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpDELETE, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]));
end;

// PATCH
function TMVCRouteGroup<T>.MapPatch(const APath: string;
  const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make0(AHandler), nil));
end;

function TMVCRouteGroup<T>.MapPatch<T1>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2, T3>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]));
end;

function TMVCRouteGroup<T>.MapPatch<T1, T2, T3, T4>(const APath: string;
  const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := TMVCRouteHandle.Create(RegisterRoute(httpPATCH, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]));
end;

// MapMethods (multi-verb)

function TMVCRouteGroup<T>.MapMethods(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make0(AHandler), nil);
end;

function TMVCRouteGroup<T>.MapMethods<T1>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make1<T1>(AHandler), [TypeInfo(T1)]);
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make2<T1, T2>(AHandler), [TypeInfo(T1), TypeInfo(T2)]);
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2, T3>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make3<T1, T2, T3>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3)]);
end;

function TMVCRouteGroup<T>.MapMethods<T1, T2, T3, T4>(const AVerbs: array of TMVCHTTPMethodType;
  const APath: string; const AHandler: TMVCMinimalFunc<T1, T2, T3, T4>): TMVCRouteHandle;
begin
  Result := RegisterMany(AVerbs, APath, TMVCThunkFactory.Make4<T1, T2, T3, T4>(AHandler), [TypeInfo(T1), TypeInfo(T2), TypeInfo(T3), TypeInfo(T4)]);
end;

initialization

gMinimalAPILock := TObject.Create;
gMinimalAPIByEngine := TDictionary<Pointer, TMVCMinimalAPIMiddleware>.Create;

finalization

gMinimalAPIByEngine.Free;
gMinimalAPILock.Free;

end.
