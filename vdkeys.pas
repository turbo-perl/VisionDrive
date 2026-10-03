{ ========================================================================== }
{  VisionDrive - Unit: VDKeys                                                 }
{                                                                            }
{  Key names, as tmux spells them, turned into the console input events a    }
{  real keyboard would have made.                                            }
{                                                                            }
{      Enter Escape Tab BTab BSpace Space                                    }
{      Up Down Left Right Home End PPage NPage IC DC                         }
{      F1 .. F12                                                             }
{                                                                            }
{  and any of those, or a single character, after C- (Ctrl), M- (Alt) or    }
{  S- (Shift), in any combination: C-F9, M-x, S-Down, C-M-Delete.  PageUp,   }
{  PageDown, Insert, Delete, Esc and Backspace are understood too.  Anything }
{  else is typed as the text it is, a character at a time.                   }
{                                                                            }
{  The events carry a virtual key code and a scan code as well as the        }
{  character, because Free Vision, like most console programs, decides       }
{  which key was pressed from those rather than from the character.          }
{ ========================================================================== }
unit VDKeys;

{$mode objfpc}{$H+}

interface

uses
  Windows, SysUtils;

type
  TKeyEvents = array of TInputRecord;

{ Add the events for one argument - a key name or some text - to Events.
  False, with Err set, if the argument cannot be typed. }
function AddKeys(const Arg: AnsiString; var Events: TKeyEvents;
                 out Err: AnsiString): Boolean;

implementation

type
  TNamedKey = record
    Name     : AnsiString;
    VK       : Word;
    Ch       : WideChar;
    Enhanced : Boolean;   { one of the keys a 101-key board added: the
                            grey arrows, Home, End and so on }
  end;

const
  Named: array[0..21] of TNamedKey = (
    (Name: 'Enter';     VK: VK_RETURN; Ch: #13; Enhanced: False),
    (Name: 'Escape';    VK: VK_ESCAPE; Ch: #27; Enhanced: False),
    (Name: 'Esc';       VK: VK_ESCAPE; Ch: #27; Enhanced: False),
    (Name: 'Tab';       VK: VK_TAB;    Ch: #9;  Enhanced: False),
    (Name: 'BSpace';    VK: VK_BACK;   Ch: #8;  Enhanced: False),
    (Name: 'Backspace'; VK: VK_BACK;   Ch: #8;  Enhanced: False),
    (Name: 'Space';     VK: VK_SPACE;  Ch: ' '; Enhanced: False),
    (Name: 'Up';        VK: VK_UP;     Ch: #0;  Enhanced: True),
    (Name: 'Down';      VK: VK_DOWN;   Ch: #0;  Enhanced: True),
    (Name: 'Left';      VK: VK_LEFT;   Ch: #0;  Enhanced: True),
    (Name: 'Right';     VK: VK_RIGHT;  Ch: #0;  Enhanced: True),
    (Name: 'Home';      VK: VK_HOME;   Ch: #0;  Enhanced: True),
    (Name: 'End';       VK: VK_END;    Ch: #0;  Enhanced: True),
    (Name: 'PPage';     VK: VK_PRIOR;  Ch: #0;  Enhanced: True),
    (Name: 'PageUp';    VK: VK_PRIOR;  Ch: #0;  Enhanced: True),
    (Name: 'NPage';     VK: VK_NEXT;   Ch: #0;  Enhanced: True),
    (Name: 'PageDown';  VK: VK_NEXT;   Ch: #0;  Enhanced: True),
    (Name: 'IC';        VK: VK_INSERT; Ch: #0;  Enhanced: True),
    (Name: 'Insert';    VK: VK_INSERT; Ch: #0;  Enhanced: True),
    (Name: 'DC';        VK: VK_DELETE; Ch: #0;  Enhanced: True),
    (Name: 'Delete';    VK: VK_DELETE; Ch: #0;  Enhanced: True),
    (Name: 'BTab';      VK: VK_TAB;    Ch: #9;  Enhanced: False));

procedure AddEvent(var Events: TKeyEvents; Down: Boolean; VK: Word;
                   Ch: WideChar; State: DWORD);
var
  N: Integer;
begin
  N := Length(Events);
  SetLength(Events, N + 1);
  FillChar(Events[N], SizeOf(Events[N]), 0);
  Events[N].EventType := KEY_EVENT;
  with Events[N].Event.KeyEvent do
  begin
    bKeyDown          := Down;
    wRepeatCount      := 1;
    wVirtualKeyCode   := VK;
    wVirtualScanCode  := MapVirtualKey(VK, 0);   { MAPVK_VK_TO_VSC }
    UnicodeChar       := Ch;
    dwControlKeyState := State;
  end;
end;

{ One key going down and coming up again. }
procedure AddPress(var Events: TKeyEvents; VK: Word; Ch: WideChar; State: DWORD);
begin
  AddEvent(Events, True,  VK, Ch, State);
  AddEvent(Events, False, VK, Ch, State);
end;

{ A character as typed: the key it is on, and Shift if it needs it. }
function AddChar(var Events: TKeyEvents; Ch: WideChar; State: DWORD;
                 out Err: AnsiString): Boolean;
var
  Scan: SmallInt;
  VK: Word;
begin
  Result := False;
  Scan := VkKeyScanW(Ch);
  if Scan = -1 then
  begin
    { Not on this keyboard: send the character with no key behind it,
      which is what pasting or an input method does. }
    AddPress(Events, 0, Ch, State);
    Exit(True);
  end;
  VK := Lo(Word(Scan));
  if (Hi(Word(Scan)) and 1) <> 0 then State := State or SHIFT_PRESSED;
  if (Hi(Word(Scan)) and 2) <> 0 then State := State or LEFT_CTRL_PRESSED;
  if (Hi(Word(Scan)) and 4) <> 0 then State := State or LEFT_ALT_PRESSED;
  { With Ctrl held a letter types its control code: C-a is #1. }
  if ((State and LEFT_CTRL_PRESSED) <> 0) and
     (UpCase(Char(Ch)) in ['@'..'_']) then
    Ch := WideChar(Ord(UpCase(Char(Ch))) - Ord('@'));
  AddPress(Events, VK, Ch, State);
  Err := '';
  Result := True;
end;

function AddKeys(const Arg: AnsiString; var Events: TKeyEvents;
                 out Err: AnsiString): Boolean;
var
  Rest: AnsiString;
  State: DWORD;
  i, F, Code: Integer;
  W: UnicodeString;
begin
  Err := '';
  Result := True;

  { Peel off the modifiers.  A lone "C-" or "M-" is text, not a modifier
    with nothing after it. }
  Rest := Arg;
  State := 0;
  while (Length(Rest) > 2) and (Rest[2] = '-') and (Rest[1] in ['C', 'M', 'S']) do
  begin
    case Rest[1] of
      'C': State := State or LEFT_CTRL_PRESSED;
      'M': State := State or LEFT_ALT_PRESSED;
      'S': State := State or SHIFT_PRESSED;
    end;
    Delete(Rest, 1, 2);
  end;

  for i := Low(Named) to High(Named) do
    if CompareText(Rest, Named[i].Name) = 0 then
    begin
      if Named[i].Name = 'BTab' then State := State or SHIFT_PRESSED;
      if Named[i].Enhanced then State := State or ENHANCED_KEY;
      AddPress(Events, Named[i].VK, Named[i].Ch, State);
      Exit;
    end;

  if (Length(Rest) >= 2) and (Length(Rest) <= 3) and (UpCase(Rest[1]) = 'F') then
  begin
    Val(Copy(Rest, 2, 2), F, Code);
    if (Code = 0) and (F >= 1) and (F <= 12) then
    begin
      AddPress(Events, VK_F1 + F - 1, #0, State);
      Exit;
    end;
  end;

  W := UTF8Decode(Rest);
  if (Length(W) = 1) or (State <> 0) then
  begin
    if Length(W) <> 1 then
    begin
      Err := 'not a key: ' + Arg;
      Exit(False);
    end;
    Exit(AddChar(Events, W[1], State, Err));
  end;

  { Plain text, a character at a time. }
  for i := 1 to Length(W) do
    if not AddChar(Events, W[i], 0, Err) then Exit(False);
end;

end.
