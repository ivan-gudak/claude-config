# install.ps1 — native Windows installer for claude-config.
#
# Symlinks require either Developer Mode (Settings > For developers)
# or running PowerShell as Administrator. If symlink creation fails,
# the script falls back to file copy automatically.
#
# Hook scripts are bash-only and NOT installed on native Windows.
# For hooks, use WSL2 and run the standard bash install.sh.
#
# Usage:
#   cd $env:USERPROFILE\.claude\claude-config
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -UseCopy    # force copy over symlink
#   powershell -ExecutionPolicy Bypass -File install.ps1 -NoPlugin   # skip workflow-tools plugin

[CmdletBinding()]
param(
    [switch]$UseCopy,
    [switch]$NoPlugin
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Split-Path -Parent $ScriptDir
$ExpectedClaudeDir = Join-Path $env:USERPROFILE '.claude'

if ($ClaudeDir -ne $ExpectedClaudeDir) {
    Write-Error @"
install.ps1 must run from within $ExpectedClaudeDir\claude-config\
  Detected script location: $ScriptDir
  Detected parent:          $ClaudeDir (expected: $ExpectedClaudeDir)

Expected setup:
  cd `$env:USERPROFILE\.claude
  git clone <repo-url> claude-config
  cd claude-config
  powershell -ExecutionPolicy Bypass -File install.ps1
"@
    exit 1
}

Write-Host "Installing claude-config from $ScriptDir"
if ($UseCopy)   { Write-Host "  (using file copy — symlinks disabled)" }
if ($NoPlugin)  { Write-Host "  (plugin skipped — -NoPlugin)" }
Write-Host "  (hooks are not installed on native Windows — use WSL2 for hook support)"

# ── Ensure target directories exist ───────────────────────────────────────────

$CommandsDir = Join-Path $ClaudeDir 'commands'
$PluginsDir  = Join-Path $ClaudeDir 'plugins'
New-Item -ItemType Directory -Force -Path $CommandsDir | Out-Null
New-Item -ItemType Directory -Force -Path $PluginsDir  | Out-Null

# ── Helpers ───────────────────────────────────────────────────────────────────

function Install-FileLink {
    param(
        [string]$Target,     # Absolute path to source file in claude-config
        [string]$LinkPath    # Absolute path of the link/copy to create
    )

    # Remove any existing item at the link path (file, symlink, or directory)
    if (Test-Path $LinkPath) { Remove-Item $LinkPath -Recurse -Force }

    if ($UseCopy) {
        Copy-Item -Path $Target -Destination $LinkPath -Force
        Write-Host "  copied $LinkPath"
        return
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        Write-Host "  linked $LinkPath"
    } catch {
        # Fall back to copy if symlink creation isn't permitted
        Copy-Item -Path $Target -Destination $LinkPath -Force
        Write-Host "  copied $LinkPath (symlink failed — Developer Mode or admin required)"
    }
}

function Install-DirectoryLink {
    param(
        [string]$Target,
        [string]$LinkPath
    )

    if (Test-Path $LinkPath) { Remove-Item $LinkPath -Recurse -Force }

    if ($UseCopy) {
        Copy-Item -Path $Target -Destination $LinkPath -Recurse -Force
        Write-Host "  copied $LinkPath (directory)"
        return
    }

    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -Force | Out-Null
        Write-Host "  linked $LinkPath (directory)"
    } catch {
        Copy-Item -Path $Target -Destination $LinkPath -Recurse -Force
        Write-Host "  copied $LinkPath (directory — symlink failed)"
    }
}

# ── Install commands ──────────────────────────────────────────────────────────

foreach ($cmd in @('impl.md', 'vuln.md', 'upgrade.md')) {
    $src = Join-Path $ScriptDir "commands\$cmd"
    $dst = Join-Path $CommandsDir $cmd
    Install-FileLink -Target $src -LinkPath $dst
}

# ── Install plugin ────────────────────────────────────────────────────────────

if (-not $NoPlugin) {
    $pluginSrc = Join-Path $ScriptDir 'plugins\workflow-tools'
    $pluginDst = Join-Path $PluginsDir 'workflow-tools'
    Install-DirectoryLink -Target $pluginSrc -LinkPath $pluginDst
}

Write-Host "Done."
Write-Host ""
Write-Host "To enable hooks, install WSL2 and run the standard bash install.sh from a WSL2 shell."
