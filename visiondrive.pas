{ ========================================================================== }
{  VisionDrive - drive a text mode program from a test.                       }
{                                                                            }
{  The program runs in a console of its own that has no window.  Each        }
{  command attaches to that console, does one thing - type keys, read the    }
{  screen - and detaches again, so a test script calls it the way it would   }
{  call tmux:                                                                }
{                                                                            }
{      visiondrive start --cols 100 --rows 30 -- myapp.exe file.txt         }
{      visiondrive keys  PID F10 Down Enter                                  }
{      visiondrive wait  PID "Save as"                                      }
{      visiondrive screen PID                                                }
{      visiondrive stop  PID                                                 }
{                                                                            }
{  The session is the program's process id, which start prints.             }
{ ========================================================================== }
program VisionDrive;

{$mode objfpc}{$H+}

{$ifndef MSWINDOWS}
  {$fatal VisionDrive drives Windows consoles; on Unix, use tmux.}
{$endif}

uses
  Windows, SysUtils, VDKeys;

const
  VDVersion = '0.01';

  ExitOK    = 0;
  ExitNo    = 1;     { a question answered no: wait timed out, not alive }
  ExitUsage = 2;
  ExitError = 3;

{ Not in Free Pascal 3.2.2's Windows unit. }
function AttachConsole(dwProcessId: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'AttachConsole';

{ In it, but taking a PChar for what is a buffer of wide characters. }
function ReadConsoleOutputCharacterW(hConsoleOutput: THandle;
  lpCharacter: PWideChar; nLength: DWORD; dwReadCoord: TCoord;
  out lpNumberOfCharsRead: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'ReadConsoleOutputCharacterW';

const
  ATTACH_PARENT_PROCESS = DWORD(-1);

procedure Usage(Code: Integer);
begin
  WriteLn('usage: visiondrive start [--cols N] [--rows N] -- PROGRAM [ARG...]');
  WriteLn('       visiondrive keys   PID KEY...');
  WriteLn('       visiondrive screen PID');
  WriteLn('       visiondrive wait   PID TEXT [--timeout MS] [--gone]');
  WriteLn('       visiondrive alive  PID');
  WriteLn('       visiondrive stop   PID');
  WriteLn('       visiondrive --version');
  Halt(Code);
end;

procedure Fail(const Msg: AnsiString);
begin
  WriteLn(StdErr, 'visiondrive: ', Msg);
  Halt(ExitError);
end;

{ -------------------------------------------------------------------------- }
{  Our own console, and visiting the program's                               }
{ -------------------------------------------------------------------------- }

var
  { Whether our output was going to a console before we left it.  A pipe
    or a file survives FreeConsole; a console handle does not, and has to
    be opened again once we are back. }
  OutIsConsole : Boolean = False;
  ErrIsConsole : Boolean = False;

procedure NoteOwnConsole;
begin
  OutIsConsole := GetFileType(GetStdHandle(STD_OUTPUT_HANDLE)) = FILE_TYPE_CHAR;
  ErrIsConsole := GetFileType(GetStdHandle(STD_ERROR_HANDLE)) = FILE_TYPE_CHAR;
end;

{ Leave our own console for the program's.  A process has at most one. }
var
  VisitError: DWORD = 0;

function Visit(Pid: DWORD): Boolean;
begin
  FreeConsole;
  Result := AttachConsole(Pid);
  if not Result then VisitError := GetLastError;
end;

{ Leave the program's console and go back to the one we came from, so that
  whatever is printed next reaches the caller rather than the program. }
procedure ComeBack;
var
  H: THandle;
begin
  FreeConsole;
  if not AttachConsole(ATTACH_PARENT_PROCESS) then Exit;
  if OutIsConsole or ErrIsConsole then
  begin
    H := CreateFile('CONOUT$', GENERIC_READ or GENERIC_WRITE,
                    FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
    if H <> INVALID_HANDLE_VALUE then
    begin
      if OutIsConsole then
      begin
        SetStdHandle(STD_OUTPUT_HANDLE, H);
        TextRec(Output).Handle := H;
      end;
      if ErrIsConsole then
      begin
        SetStdHandle(STD_ERROR_HANDLE, H);
        TextRec(StdErr).Handle := H;
      end;
    end;
  end;
end;

function OpenConsoleFile(const Name: AnsiString): THandle;
begin
  Result := CreateFile(PChar(Name), GENERIC_READ or GENERIC_WRITE,
                       FILE_SHARE_READ or FILE_SHARE_WRITE, nil, OPEN_EXISTING, 0, 0);
end;

{ -------------------------------------------------------------------------- }
{  The screen                                                                }
{ -------------------------------------------------------------------------- }

{ What is on the program's screen, a line per row of the console window,
  with trailing spaces trimmed.  Must be called while visiting. }
function ReadScreen(out Lines: TStringArray): Boolean;
var
  Con  : THandle;
  Info : TConsoleScreenBufferInfo;
  Row, Width: Integer;
  Buf  : UnicodeString;
  Got  : DWORD;
  At   : TCoord;
begin
  Result := False;
  SetLength(Lines, 0);
  Con := OpenConsoleFile('CONOUT$');
  if Con = INVALID_HANDLE_VALUE then Exit;
  try
    if not GetConsoleScreenBufferInfo(Con, Info) then Exit;
    Width := Info.srWindow.Right - Info.srWindow.Left + 1;
    SetLength(Lines, Info.srWindow.Bottom - Info.srWindow.Top + 1);
    SetLength(Buf, Width);
    for Row := 0 to High(Lines) do
    begin
      At.X := Info.srWindow.Left;
      At.Y := Info.srWindow.Top + Row;
      Got := 0;
      if not ReadConsoleOutputCharacterW(Con, PWideChar(Buf), Width, At, Got) then
        Exit;
      Lines[Row] := TrimRight(UTF8Encode(Copy(Buf, 1, Got)));
    end;
    Result := True;
  finally
    CloseHandle(Con);
  end;
end;

{ -------------------------------------------------------------------------- }
{  Commands                                                                  }
{ -------------------------------------------------------------------------- }

function ParsePid(const S: AnsiString): DWORD;
var
  V, Code: Integer;
begin
  Val(S, V, Code);
  if (Code <> 0) or (V <= 0) then Fail('not a process id: ' + S);
  Result := DWORD(V);
end;

function IsAlive(Pid: DWORD): Boolean;
var
  H: THandle;
  Code: DWORD;
begin
  Result := False;
  H := OpenProcess(PROCESS_QUERY_INFORMATION, False, Pid);
  if H = 0 then Exit;
  if GetExitCodeProcess(H, Code) then Result := Code = STILL_ACTIVE;
  CloseHandle(H);
end;

{ Quote an argument for a Windows command line, by the rules the C runtime
  splits it with. }
function QuoteArg(const Arg: AnsiString): AnsiString;
var
  i, Slashes: Integer;
begin
  Result := '"';
  Slashes := 0;
  for i := 1 to Length(Arg) do
    case Arg[i] of
      '\': Inc(Slashes);
      '"':
        begin
          Result := Result + StringOfChar('\', Slashes * 2 + 1) + '"';
          Slashes := 0;
        end;
    else
      Result := Result + StringOfChar('\', Slashes) + Arg[i];
      Slashes := 0;
    end;
  Result := Result + StringOfChar('\', Slashes * 2) + '"';
end;

{ Free Pascal 3.2.2's Windows unit has no job objects. }
{$push}{$packrecords c}
type
  TJobBasicLimits = record
    PerProcessUserTimeLimit : Int64;
    PerJobUserTimeLimit     : Int64;
    LimitFlags              : DWORD;
    MinimumWorkingSetSize   : PtrUInt;
    MaximumWorkingSetSize   : PtrUInt;
    ActiveProcessLimit      : DWORD;
    Affinity                : PtrUInt;
    PriorityClass           : DWORD;
    SchedulingClass         : DWORD;
  end;
  TJobExtendedLimits = record
    Basic                 : TJobBasicLimits;
    IoCounters            : array[0..5] of QWord;
    ProcessMemoryLimit    : PtrUInt;
    JobMemoryLimit        : PtrUInt;
    PeakProcessMemoryUsed : PtrUInt;
    PeakJobMemoryUsed     : PtrUInt;
  end;
{$pop}

const
  JobObjectExtendedLimitInformation = 9;
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = $2000;

function CreateJobObjectW(lpJobAttributes: Pointer; lpName: PWideChar): THandle;
  stdcall; external 'kernel32.dll' name 'CreateJobObjectW';
function AssignProcessToJobObject(hJob, hProcess: THandle): BOOL;
  stdcall; external 'kernel32.dll' name 'AssignProcessToJobObject';
function SetInformationJobObject(hJob: THandle; JobObjectInfoClass: DWORD;
  lpJobObjectInfo: Pointer; cbJobObjectInfoLength: DWORD): BOOL;
  stdcall; external 'kernel32.dll' name 'SetInformationJobObject';

{ The event a host sets once the program is running in a console of the
  right size, named for the host so that sessions cannot mix them up. }
function ReadyEventName(HostPid: DWORD): AnsiString;
begin
  Result := 'Local\VisionDrive-ready-' + IntToStr(HostPid);
end;

{ Read --cols, --rows and the -- that ends them, from the arguments after
  the command.  First is the index of the program's name. }
procedure ParseSize(out Cols, Rows, First: Integer);
var
  i, Code: Integer;
begin
  Cols := 80;
  Rows := 25;
  First := 0;
  i := 2;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '--' then
    begin
      First := i + 1;
      Break;
    end
    else if (ParamStr(i) = '--cols') and (i < ParamCount) then
    begin
      Val(ParamStr(i + 1), Cols, Code);
      if (Code <> 0) or (Cols < 1) then Usage(ExitUsage);
      Inc(i, 2);
    end
    else if (ParamStr(i) = '--rows') and (i < ParamCount) then
    begin
      Val(ParamStr(i + 1), Rows, Code);
      if (Code <> 0) or (Rows < 1) then Usage(ExitUsage);
      Inc(i, 2);
    end
    else
      Usage(ExitUsage);
  end;
  if (First = 0) or (First > ParamCount) then Usage(ExitUsage);
end;

{ The command line for ParamStr(First) onwards. }
function CommandFrom(First: Integer): AnsiString;
var
  i: Integer;
begin
  Result := QuoteArg(ParamStr(First));
  for i := First + 1 to ParamCount do
    Result := Result + ' ' + QuoteArg(ParamStr(i));
end;

{ start: a console with no window for the program, and a host in it.

  Windows takes the size asked for in STARTUPINFO as no more than a hint,
  and a program reads its screen size as it starts, so the console has to
  be the right size before the program is in it.  The host, which is this
  same program run again, makes it so, starts the program, and says when it
  is ready.  The session is the host's process id; the host lives exactly
  as long as the program does. }
procedure CmdStart;
var
  Cols, Rows, First: Integer;
  Line: AnsiString;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Ready: THandle;
  Waits: array[0..1] of THandle;
begin
  ParseSize(Cols, Rows, First);
  Line := QuoteArg(ParamStr(0)) + ' __host --cols ' + IntToStr(Cols) +
          ' --rows ' + IntToStr(Rows) + ' -- ' + CommandFrom(First);

  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW;
  SI.wShowWindow := SW_HIDE;
  FillChar(PI, SizeOf(PI), 0);
  UniqueString(Line);
  { Suspended until the event it will set exists. }
  if not CreateProcess(nil, PChar(Line), nil, nil, False,
                       CREATE_NEW_CONSOLE or CREATE_NEW_PROCESS_GROUP or
                       CREATE_SUSPENDED, nil, nil, SI, PI) then
    Fail('could not start a console: ' + SysErrorMessage(GetLastError));
  Ready := CreateEvent(nil, True, False, PChar(ReadyEventName(PI.dwProcessId)));
  ResumeThread(PI.hThread);
  CloseHandle(PI.hThread);

  Waits[0] := Ready;
  Waits[1] := PI.hProcess;
  case WaitForMultipleObjects(2, @Waits[0], False, 10000) of
    WAIT_OBJECT_0: ;
    WAIT_OBJECT_0 + 1:
      Fail('could not start ' + ParamStr(First));
  else
    TerminateProcess(PI.hProcess, 1);
    Fail('timed out starting ' + ParamStr(First));
  end;
  CloseHandle(Ready);
  CloseHandle(PI.hProcess);
  WriteLn(PI.dwProcessId);
end;

{ Make the console Cols by Rows, window and buffer alike.  The window can
  never be larger than the buffer, so it is shrunk out of the way first. }
procedure SizeConsole(Cols, Rows: Integer);
var
  Con: THandle;
  R: TSmallRect;
  Size: TCoord;
begin
  Con := GetStdHandle(STD_OUTPUT_HANDLE);
  R.Left := 0; R.Top := 0; R.Right := 0; R.Bottom := 0;
  SetConsoleWindowInfo(Con, True, R);
  Size.X := Cols;
  Size.Y := Rows;
  SetConsoleScreenBufferSize(Con, Size);
  R.Right := Cols - 1;
  R.Bottom := Rows - 1;
  SetConsoleWindowInfo(Con, True, R);
end;

{ __host: run in the new console by start, never by hand. }
procedure CmdHost;
var
  Cols, Rows, First: Integer;
  Line: AnsiString;
  SI: TStartupInfo;
  PI: TProcessInformation;
  Job, Ready: THandle;
  Limits: TJobExtendedLimits;
  Code: DWORD;
begin
  ParseSize(Cols, Rows, First);
  SizeConsole(Cols, Rows);

  { The program goes in a job that dies with the host, so that stopping
    the session - killing the host - takes the program and anything it
    started with it. }
  Job := CreateJobObjectW(nil, nil);
  FillChar(Limits, SizeOf(Limits), 0);
  Limits.Basic.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  SetInformationJobObject(Job, JobObjectExtendedLimitInformation,
                          @Limits, SizeOf(Limits));

  Line := CommandFrom(First);
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  FillChar(PI, SizeOf(PI), 0);
  UniqueString(Line);
  if not CreateProcess(nil, PChar(Line), nil, nil, False, CREATE_SUSPENDED,
                       nil, nil, SI, PI) then
    Halt(ExitError);
  AssignProcessToJobObject(Job, PI.hProcess);
  ResumeThread(PI.hThread);
  CloseHandle(PI.hThread);

  Ready := OpenEvent(EVENT_MODIFY_STATE, False,
                     PChar(ReadyEventName(GetCurrentProcessId)));
  if Ready <> 0 then
  begin
    SetEvent(Ready);
    CloseHandle(Ready);
  end;

  WaitForSingleObject(PI.hProcess, INFINITE);
  if not GetExitCodeProcess(PI.hProcess, Code) then Code := ExitError;
  Halt(Code);
end;

procedure CmdScreen;
var
  Pid: DWORD;
  Lines: TStringArray;
  OK: Boolean;
  i: Integer;
begin
  if ParamCount <> 2 then Usage(ExitUsage);
  Pid := ParsePid(ParamStr(2));
  OK := Visit(Pid) and ReadScreen(Lines);
  ComeBack;
  if not OK then
    Fail('cannot read the screen of ' + ParamStr(2) + ': ' + SysErrorMessage(VisitError));
  for i := 0 to High(Lines) do WriteLn(Lines[i]);
end;

procedure CmdKeys;
var
  Pid: DWORD;
  Con: THandle;
  Events: TKeyEvents;
  i: Integer;
  Written: DWORD;
  Err: AnsiString;
begin
  if ParamCount < 3 then Usage(ExitUsage);
  Pid := ParsePid(ParamStr(2));
  SetLength(Events, 0);
  for i := 3 to ParamCount do
    if not AddKeys(ParamStr(i), Events, Err) then Fail(Err);

  Err := '';
  if not Visit(Pid) then
    Err := 'cannot attach to ' + ParamStr(2)
  else
  begin
    Con := OpenConsoleFile('CONIN$');
    if Con = INVALID_HANDLE_VALUE then
      Err := 'cannot open the input of ' + ParamStr(2)
    else
    begin
      if (Length(Events) > 0) and
         not WriteConsoleInputW(Con, Events[0], Length(Events), Written) then
        Err := 'cannot type into ' + ParamStr(2);
      CloseHandle(Con);
    end;
  end;
  ComeBack;
  if Err <> '' then Fail(Err);
end;

procedure CmdWait;
var
  Pid: DWORD;
  Text: AnsiString;
  Timeout, Code, i: Integer;
  Gone, Found, Read: Boolean;
  Lines: TStringArray;
  Started: QWord;
begin
  if ParamCount < 3 then Usage(ExitUsage);
  Pid := ParsePid(ParamStr(2));
  Text := ParamStr(3);
  Timeout := 10000;
  Gone := False;
  i := 4;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--timeout') and (i < ParamCount) then
    begin
      Val(ParamStr(i + 1), Timeout, Code);
      if Code <> 0 then Usage(ExitUsage);
      Inc(i, 2);
    end
    else if ParamStr(i) = '--gone' then
    begin
      Gone := True;
      Inc(i);
    end
    else
      Usage(ExitUsage);
  end;

  Started := GetTickCount64;
  repeat
    Read := Visit(Pid) and ReadScreen(Lines);
    ComeBack;
    { A program that is still starting may not have a screen yet.  One that
      has gone has certainly stopped showing the text. }
    if not Read and not IsAlive(Pid) then
    begin
      if Gone then Halt(ExitOK);
      Fail('no session ' + ParamStr(2));
    end;
    if Read then
    begin
      Found := False;
      for i := 0 to High(Lines) do
        if Pos(Text, Lines[i]) > 0 then Found := True;
      if Found <> Gone then Halt(ExitOK);
    end;
    Sleep(50);
  until GetTickCount64 - Started > QWord(Timeout);
  Halt(ExitNo);
end;

procedure CmdAlive;
begin
  if ParamCount <> 2 then Usage(ExitUsage);
  if IsAlive(ParsePid(ParamStr(2))) then Halt(ExitOK) else Halt(ExitNo);
end;

procedure CmdStop;
var
  H: THandle;
begin
  if ParamCount <> 2 then Usage(ExitUsage);
  H := OpenProcess(PROCESS_TERMINATE, False, ParsePid(ParamStr(2)));
  if H = 0 then Exit;     { already gone }
  TerminateProcess(H, 1);
  CloseHandle(H);
end;

var
  Cmd: AnsiString;
begin
  if ParamCount < 1 then Usage(ExitUsage);
  NoteOwnConsole;
  Cmd := ParamStr(1);
  if      Cmd = 'start'  then CmdStart
  else if Cmd = '__host' then CmdHost
  else if Cmd = 'keys'   then CmdKeys
  else if Cmd = 'screen' then CmdScreen
  else if Cmd = 'wait'   then CmdWait
  else if Cmd = 'alive'  then CmdAlive
  else if Cmd = 'stop'   then CmdStop
  else if (Cmd = '--version') or (Cmd = '-v') then WriteLn('visiondrive ', VDVersion)
  else if (Cmd = '--help') or (Cmd = '-h') then Usage(ExitOK)
  else Usage(ExitUsage);
end.
