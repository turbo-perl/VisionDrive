# VisionDrive

Drive a full screen text mode program from a test: start it, type keys at
it, and read back what it put on the screen.  It was written for Free
Vision programs, but works with any Windows console program.

It does for Windows what tmux does for the interface tests of Unix
programs, and is used the same way, one command at a time from a test
script:

```
visiondrive start --cols 100 --rows 30 -- myapp.exe file.txt
visiondrive keys   PID M-f Down Enter
visiondrive wait   PID "Save as"
visiondrive screen PID
visiondrive stop   PID
```

`start` prints the session's id, a process id, which the other commands
take.

## Commands

| Command | |
|---|---|
| `start [--cols N] [--rows N] -- PROGRAM [ARG...]` | run PROGRAM in a console of its own, N columns by N rows (80 by 25 unless told), with no window; prints the session id |
| `keys PID KEY...` | type the keys, in order |
| `screen PID` | print the screen, a line per row, trailing spaces trimmed, as UTF-8 |
| `wait PID TEXT [--timeout MS] [--gone]` | wait until TEXT is on the screen, or with `--gone` until it is not; 10 seconds unless told |
| `alive PID` | whether the program is still running |
| `stop PID` | end the program, and anything it started |

Exit status is 0 for success, 1 for a no (`wait` timed out, `alive` found
nothing running), 2 for a usage error and 3 for anything else.

## Keys

Keys are named the way tmux names them:

- `Enter` `Escape` `Tab` `BTab` `BSpace` `Space`
- `Up` `Down` `Left` `Right` `Home` `End` `PPage` `NPage` `IC` `DC`
- `F1` to `F12`

`PageUp`, `PageDown`, `Insert`, `Delete`, `Esc` and `Backspace` work too.
Any of them, or a single character, can follow `C-` (Ctrl), `M-` (Alt) and
`S-` (Shift), in any combination: `C-F9`, `M-x`, `S-Down`.  Anything else
is typed as text, a character at a time, so `keys PID "hello world" Enter`
types the words and presses Enter.

Each key arrives as a real keyboard would send it, with a virtual key code
and a scan code as well as the character.  Free Vision, like most console
programs, goes by those rather than the character, which is why F-keys and
Alt combinations work here where they can go astray through a terminal.

## How it works

`start` makes a console with no window, and runs VisionDrive again inside
it as a host.  The host sizes the console, since Windows treats the size
asked for when a console is made as no more than a hint and a program reads
its screen size as it starts, then runs the program in a job object that
ends with the host.  The session id is the host's process id.

Every other command attaches to the session's console, does its one thing
with the console API - `WriteConsoleInputW` to type, `ReadConsoleOutputCharacterW`
to read - and detaches again.  There is no server to start or
clean up after.

Programs that draw through the console API, as Free Vision's video unit
does on Windows, are read exactly as drawn.

## Building

Needs only Free Pascal:

```
fpc -Px86_64 -FUunits visiondrive.pas
```

`-Px86_64` builds 64-bit with the cross compiler the Windows installer
includes; leave it off for 32-bit.  Windows only: on Unix, use tmux.

## Licence

Copyright (c) 2026 Graham Ollis.  This is free software; you can
redistribute it and/or modify it under the same terms as the Perl 5
programming language system itself: the GNU General Public License,
version 1 or later, or the Artistic License.  See `LICENSE`.
