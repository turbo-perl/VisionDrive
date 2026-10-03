# VisionDrive's own tests: drive tests\keyecho.exe, which prints each key
# as the console reports it, and check what it saw.
#
#   powershell -File tests\run.ps1        (or pwsh)
#
# Expects visiondrive.exe and tests\keyecho.exe to be built.

# Not Stop: under Windows PowerShell that makes anything a program writes
# to stderr fatal, and the checks go by exit status anyway.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$vd   = Join-Path $root 'visiondrive.exe'
$echo = Join-Path $root 'tests\keyecho.exe'
$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Output "ok   $name" }
    else     { $script:fail++; Write-Output "FAIL $name" }
}

# Wait for TEXT on the screen of session ID.
function Sees($id, [string]$text) {
    & $vd wait $id $text --timeout 5000 | Out-Null
    return $LASTEXITCODE -eq 0
}

# A key, and the line keyecho should print for it.
function Key($id, [string]$name, [string]$expect) {
    & $vd keys $id $name
    Check "$name arrives as $expect" (Sees $id $expect)
}

$id = & $vd start --cols 90 --rows 20 -- $echo
Check 'start prints a session id' ($id -match '^\d+$')
Check 'the console is the size asked for' (Sees $id 'ready 90x20')
Check 'the screen has as many rows' ((& $vd screen $id).Count -eq 20)
$esc = [char]27
Check 'screen -e gives the colours as ANSI escapes' `
    ((& $vd screen $id -e)[0] -eq "$esc[37m$esc[40mready 90x20$esc[0m")

Key $id 'F8'      'key vk=119 char=0 ctrl=0 alt=0 shift=0'
Key $id 'C-F9'    'key vk=120 char=0 ctrl=1 alt=0 shift=0'
Key $id 'M-x'     'key vk=88 char=120 ctrl=0 alt=1 shift=0'
Key $id 'C-a'     'key vk=65 char=1 ctrl=1 alt=0 shift=0'
Key $id 'S-Down'  'key vk=40 char=0 ctrl=0 alt=0 shift=1'
Key $id 'Enter'   'key vk=13 char=13 ctrl=0 alt=0 shift=0'
Key $id 'BTab'    'key vk=9 char=9 ctrl=0 alt=0 shift=1'
Key $id 'PageUp'  'key vk=33 char=0 ctrl=0 alt=0 shift=0'

& $vd keys $id 'Hi!'
Check 'text types each character' ((Sees $id 'key vk=72 char=72') -and
                                   (Sees $id 'key vk=73 char=105') -and
                                   (Sees $id 'char=33 ctrl=0 alt=0 shift=1'))

& $vd wait $id 'not on the screen' --timeout 300 | Out-Null
Check 'wait gives up with 1' ($LASTEXITCODE -eq 1)

& $vd keys $id Escape
& $vd wait $id 'ready' --gone --timeout 5000 | Out-Null
Check 'wait --gone sees the program end' ($LASTEXITCODE -eq 0)
Start-Sleep -Milliseconds 300
& $vd alive $id
Check 'alive says no once it has ended' ($LASTEXITCODE -eq 1)

$id = & $vd start -- $echo
Check 'the size is 80 by 25 unless asked' (Sees $id 'ready 80x25')
& $vd stop $id
Start-Sleep -Milliseconds 300
& $vd alive $id
Check 'stop ends the program' ($LASTEXITCODE -eq 1)

& $vd keys 2>$null
Check 'a usage error gives 2' ($LASTEXITCODE -eq 2)

Write-Output ''
Write-Output "visiondrive tests: $script:pass passed, $script:fail failed"
# Explicitly: otherwise the status is that of the last program run, and
# the last check runs one that fails on purpose.
if ($script:fail -gt 0) { exit 1 }
exit 0
