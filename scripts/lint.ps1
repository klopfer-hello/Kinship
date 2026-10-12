# Lints the addon with luacheck (config: .luacheckrc). Exit code != 0 on warnings.
# Install once: gh release download v1.2.0 --repo lunarmodules/luacheck --pattern luacheck.exe -D $HOME\.local\bin
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$luacheck = Get-Command luacheck -ErrorAction SilentlyContinue
if (-not $luacheck) { throw "luacheck not found on PATH (see the install line at the top of this script)" }
Push-Location $root
try {
    & $luacheck.Source . --formatter plain @args
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
