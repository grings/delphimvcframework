unit WebModuleUnit1;

interface

uses System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  MVCFramework;

type
  TWebModule1 = class(TWebModule)
    procedure WebModuleCreate(Sender: TObject);

  private
    MVC: TMVCEngine;

  public
    { Public declarations }
  end;

var
  WebModuleClass: TComponentClass = TWebModule1;
  SessionType: String = 'memory';

implementation

{$R *.dfm}


uses
  AppControllerU, MVCFramework.Commons;

procedure TWebModule1.WebModuleCreate(Sender: TObject);
begin
  MVC := TMVCEngine.Create(Self,
    procedure(Config: TMVCConfig)
    begin
      Config[TMVCConfigKey.SessionTimeout] := '10'; // 10minutes
      Config[TMVCConfigKey.DefaultContentType] := TMVCMediaType.TEXT_HTML;
      Config[TMVCConfigKey.SessionType] := SessionType;
    end);
  MVC.AddController(TApp1MainController);
end;

end.
