[Setup]
AppName=Cure Yesu Mwana Wa Mtu
AppVersion=1.0.0
AppPublisher=Cure Yesu Mwana Wa Mtu
DefaultDirName={autopf}\Cure Yesu Mwana Wa Mtu
DefaultGroupName=Cure Yesu Mwana Wa Mtu
OutputDir=.
OutputBaseFilename=Cure-Yesu-Mwana-Wa-Mtu-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
WizardStyle=modern
SetupIconFile=assets\icons\babu.ico
UninstallDisplayIcon={app}\babu.ico
MinVersion=10.0.17763
DisableWelcomePage=no

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "assets\icons\babu.ico"; DestDir: "{app}"; DestName: "babu.ico"; Flags: ignoreversion
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{commondesktop}\Cure Yesu Mwana Wa Mtu"; Filename: "{app}\CureYesuMwanaWaMtu.exe"; IconFilename: "{app}\babu.ico"
Name: "{group}\Cure Yesu Mwana Wa Mtu"; Filename: "{app}\CureYesuMwanaWaMtu.exe"; IconFilename: "{app}\babu.ico"

[Run]
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installation des composants requis (Visual C++)..."; Check: VCRedistNeedsInstall; Flags: waituntilterminated

[Code]
function VCRedistNeedsInstall(): Boolean;
var
  Installed: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', 'Installed', Installed) then
  begin
    if Installed = 1 then
      Result := False;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorCode: Integer;
begin
  if CurStep = ssDone then
  begin
    ShellExecAsOriginalUser('open', ExpandConstant('{app}\CureYesuMwanaWaMtu.exe'), '', ExpandConstant('{app}'), SW_SHOWNORMAL, ewNoWait, ErrorCode);
  end;
end;
