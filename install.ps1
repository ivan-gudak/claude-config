# install.ps1 - native Windows installer for claude-config.
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

[CmdletBinding()]
param(
    [switch]$UseCopy
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
if ($UseCopy)   { Write-Host "  (using file copy - symlinks disabled)" }
Write-Host "  (hooks are not installed on native Windows - use WSL2 for hook support)"

# -- Ensure target directories exist -------------------------------------------

$CommandsDir = Join-Path $ClaudeDir 'commands'
$AgentsDir   = Join-Path $ClaudeDir 'agents'
New-Item -ItemType Directory -Force -Path $CommandsDir | Out-Null
New-Item -ItemType Directory -Force -Path $AgentsDir   | Out-Null

# -- Helpers -------------------------------------------------------------------

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
        Write-Host "  copied $LinkPath (symlink failed - Developer Mode or admin required)"
    }
}

# -- Install commands ----------------------------------------------------------

foreach ($cmd in @('impl.md', 'vuln.md', 'upgrade.md')) {
    $src = Join-Path $ScriptDir "commands\$cmd"
    $dst = Join-Path $CommandsDir $cmd
    Install-FileLink -Target $src -LinkPath $dst
}

# -- Install agents (user-level subagents) -------------------------------------
# Claude Code auto-discovers agents placed at ~/.claude/agents/<name>.md
# via their YAML frontmatter. Replaces the earlier plugin-based approach, which
# required marketplace registration Claude Code's local-dir discovery does not
# support.

foreach ($agent in @('test-baseline.md', 'risk-planner.md', 'code-review.md', 'review-fixer.md', 'impl-maintenance.md')) {
    $src = Join-Path $ScriptDir "agents\$agent"
    $dst = Join-Path $AgentsDir $agent
    Install-FileLink -Target $src -LinkPath $dst
}

# -- Cleanup: remove legacy plugins\workflow-tools\ if left from a prior install
$LegacyPlugin = Join-Path $ClaudeDir 'plugins\workflow-tools'
if (Test-Path $LegacyPlugin) {
    Remove-Item $LegacyPlugin -Recurse -Force
    Write-Host "  removed legacy plugins\workflow-tools\ (no longer used)"
}
# Drop the parent plugins\ dir if it's empty after cleanup.
$PluginsParent = Join-Path $ClaudeDir 'plugins'
if (Test-Path $PluginsParent) {
    $remaining = Get-ChildItem -Path $PluginsParent -Force -ErrorAction SilentlyContinue
    if (-not $remaining) {
        Remove-Item $PluginsParent -Force
    }
}

Write-Host "Done."
Write-Host ""
Write-Host "To enable hooks, install WSL2 and run the standard bash install.sh from a WSL2 shell."
