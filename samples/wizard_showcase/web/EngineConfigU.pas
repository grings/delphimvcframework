// ***************************************************************************
//
// Delphi MVC Framework
//
// Copyright (c) 2010-2026 Daniele Teti and the DMVCFramework Team
//
// https://github.com/danieleteti/delphimvcframework
//
// ***************************************************************************


unit EngineConfigU;

interface

uses
  MVCFramework;

procedure ConfigureEngine(AEngine: TMVCEngine);

implementation

uses
  System.IOUtils,
  System.DateUtils,
  TemplatePro,
  MVCFramework.View.Renderers.TemplatePro,
  MVCFramework.Commons,
  MVCFramework.Logger,
  MVCFramework.Middleware.Redirect,
  System.SysUtils;

procedure ConfigureEngine(AEngine: TMVCEngine);
begin

  // Controllers
  // Controllers - END
  // Minimal API mode: routes are wired by ConfigureRoutes(LEngine.Root)
  // called explicitly from the .dpr right after ConfigureEngine. Cross-
  // cutting concerns (auth, logging, rate-limit) live in RoutesU as
  // endpoint filters applied via .Use() on route groups — NOT as engine-
  // wide AddMiddleware calls.

  // Server Side View
  AEngine.SetViewEngine(TMVCTemplateProViewEngine);
  // Server Side View - END


  // Exception handler for server-side views (browser requests only)
  AEngine.SetExceptionHandler(
    procedure(E: Exception; SelectedController: TMVCController;
      WebContext: TWebContext; var ExceptionHandled: Boolean)
    var
      lError: String;
      lTemplateCode: String;
      lFullTemplatePath, lTemplateCodePath: String;
    begin
      ExceptionHandled := False;
      if not WebContext.Request.ClientPreferHTML then
        Exit;
      lFullTemplatePath := TPath.Combine(AppPath, WebContext.Config[TMVCConfigKey.ViewPath]);
      lTemplateCodePath := TPath.Combine(lFullTemplatePath,
        'error.' + WebContext.Config[TMVCConfigKey.DefaultViewFileExtension]);
      if TFile.Exists(lTemplateCodePath) then
      begin
        if Assigned(E) then
        begin
          lError := E.Message;
          LogException(E);
        end
        else
        begin
          lError := IntToStr(WebContext.Response.StatusCode) + ' ' +
            HTTP_STATUS.ReasonStringFor(WebContext.Response.StatusCode);
          LogE(lError);
        end;
        WebContext.Response.ContentType := TMVCMediaType.TEXT_HTML;
        lTemplateCode := TFile.ReadAllText(lTemplateCodePath, TEncoding.UTF8);
        WebContext.Response.Content := TTProCompiler.CompileAndRender(
          lTemplateCode,
          ['error', 'app_name', 'dmvc_version', 'current_year'],
          [lError, 'TestProject', DMVCFRAMEWORK_VERSION, YearOf(Now)],
          lFullTemplatePath);
        ExceptionHandled := True;
      end;
    end
  );

end;

end.
