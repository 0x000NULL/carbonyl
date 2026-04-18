<#
.SYNOPSIS
  Launch Carbonyl on Windows.

.EXAMPLE
  .\run.ps1 https://github.com
  .\run.ps1 -Target win-x64 https://news.ycombinator.com
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Target = "win-x64",

    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Urls
)

$carbonylRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin = Join-Path $carbonylRoot "chromium\src\out\$Target\headless_shell.exe"

if (-not (Test-Path $bin)) {
    Write-Error "headless_shell.exe not found at $bin -- run validate-m4.ps1 to build first."
    exit 1
}

& $bin @Urls
