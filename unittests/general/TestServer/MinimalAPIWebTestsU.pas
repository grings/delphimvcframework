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
// *************************************************************************** }

unit MinimalAPIWebTestsU;

interface

uses
  MVCFramework,
  MVCFramework.Commons,
  MVCFramework.MinimalAPI;

procedure RegisterMinimalAPIWebRoutes(AEngine: TMVCEngine);

implementation

uses
  System.SysUtils,
  System.Classes;

type
  TLoginForm = record
    [MVCFromContentField('username')] Username: string;
    [MVCFromContentField('password')] Password: string;
    [MVCFromContentField('remember', 'false')] Remember: Boolean;
  end;

procedure RegisterMinimalAPIWebRoutes(AEngine: TMVCEngine);
begin
  // -- routing test: simple WebRoot GET returns text/html
  AEngine.WebRoot.MapGet('/minimal-web/hello',
    function: IMVCResponse
    begin
      ViewData['who'] := 'world';
      Result := RenderView('minimal_web_hello');
    end);

  // -- ViewData test: round-trip a few keys via Ctx.ViewData
  AEngine.WebRoot.MapGet<TWebContext>('/minimal-web/viewdata',
    function (Ctx: TWebContext): IMVCResponse
    begin
      Ctx.ViewData['a'] := 'alpha';
      Ctx.ViewData['b'] := 'beta';
      Result := RenderView('minimal_web_viewdata');
    end);

  // -- form binding test
  AEngine.WebRoot.MapPost<TLoginForm>('/minimal-web/login',
    function (F: TLoginForm): IMVCResponse
    begin
      ViewData['username'] := F.Username;
      ViewData['remember'] := F.Remember;
      Result := RenderView('minimal_web_login_result');
    end);

  // -- filter renders error page
  AEngine.WebRoot
    .Use(
      function (const Ctx: TWebContext;
        const Next: TMVCEndpointFilterNext): IMVCResponse
      begin
        if Ctx.Request.Params['block'] = '1' then
          Result := RenderView('minimal_web_blocked')
        else
          Result := Next();
      end)
    .MapGet('/minimal-web/filter',
      function: IMVCResponse
      begin
        Result := RenderView('minimal_web_filter_ok');
      end);

  // -- OpenAPI: API + Web siblings, plus a web route opted in
  AEngine.Root.MapGet('/minimal-web/api-side',
    function: IMVCResponse
    begin
      Result := Ok('api');
    end);
  AEngine.WebRoot.MapGet('/minimal-web/web-side',
    function: IMVCResponse
    begin
      Result := RenderView('minimal_web_side');
    end);
  AEngine.WebRoot.MapGet('/minimal-web/web-visible',
    function: IMVCResponse
    begin
      Result := RenderView('minimal_web_side');
    end).WithOpenAPI(True);

  // -- threadvar isolation: parameterised endpoint that echoes a marker
  AEngine.WebRoot.MapGet<string>('/minimal-web/iso/($marker)',
    function (Marker: string): IMVCResponse
    begin
      ViewData['marker'] := Marker;
      Result := RenderView('minimal_web_iso');
    end);
end;

end.
