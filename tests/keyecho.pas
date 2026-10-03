{ Prints each key it is sent, as the console reports it, so that a test
  can check VisionDrive types what it says it does.  One line per key
  pressed:

      key vk=119 char=0 ctrl=0 alt=0 shift=0 scan=66

  with the scan code last, as the one part that depends on the keyboard.
  It prints "ready" and its console's size first, and stops after Escape. }
program KeyEcho;

{$mode objfpc}{$H+}

uses
  Windows, SysUtils;

var
  Con: THandle;
  Rec: TInputRecord;
  Info: TConsoleScreenBufferInfo;
  Got: DWORD;
  State: DWORD;

function Flag(Mask: DWORD): Integer;
begin
  if (State and Mask) <> 0 then Result := 1 else Result := 0;
end;

begin
  Con := GetStdHandle(STD_INPUT_HANDLE);
  SetConsoleMode(Con, 0);
  GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), Info);
  WriteLn('ready ', Info.srWindow.Right - Info.srWindow.Left + 1, 'x',
          Info.srWindow.Bottom - Info.srWindow.Top + 1);
  repeat
    if not ReadConsoleInputW(Con, Rec, 1, Got) then Halt(1);
    if (Rec.EventType <> KEY_EVENT) or not Rec.Event.KeyEvent.bKeyDown then
      Continue;
    with Rec.Event.KeyEvent do
    begin
      State := dwControlKeyState;
      WriteLn(Format('key vk=%d char=%d ctrl=%d alt=%d shift=%d scan=%d',
        [wVirtualKeyCode, Ord(UnicodeChar),
         Flag(LEFT_CTRL_PRESSED or RIGHT_CTRL_PRESSED),
         Flag(LEFT_ALT_PRESSED or RIGHT_ALT_PRESSED),
         Flag(SHIFT_PRESSED), wVirtualScanCode]));
      if wVirtualKeyCode = VK_ESCAPE then Break;
    end;
  until False;
end.
