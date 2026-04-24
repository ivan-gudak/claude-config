# uninstall.ps1 - reverse of install.ps1 for native Windows.
#
# Removes managed symlinks (or copies) and strips our hook entries from
# settings.json if any are present. Idempotent: safe to re-run.
#
# Usage:
#   cd $env:USERPROFILE\.claude\claude-config
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir = Split-Path -Parent $ScriptDir
$ExpectedClaudeDir = Join-Path $env:USERPROFILE '.claude'

if ($ClaudeDir -ne $ExpectedClaudeDir) {
    Write-Error @"
uninstall.ps1 must run from within $ExpectedClaudeDir\claude-config\
  Detected script location: $ScriptDir
  Detected parent:          $ClaudeDir (expected: $ExpectedClaudeDir)
"@
    exit 1
}

Write-Host "Uninstalling claude-config from $ClaudeDir"

# -- Remove managed items (symlinks OR copied files/dirs) ----------------------
# For symlinks: only remove if the target points into claude-config/.
# For copies (non-symlinks): always remove - they only exist because we put them there.

function Remove-IfOurs {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return }

    $item = Get-Item $Path -Force
    $isLink = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint

    if ($isLink) {
        $target = $item.Target
        # Require a path separator before or after claude-config to avoid matching
        # e.g. "claude-config-backup". Targets may use forward or back slashes.
        if ($target -and ($target -like "*/claude-config/*" -or
                          $target -like "*\claude-config\*" -or
                          $target -like "../claude-config/*" -or
                          $target -like "..\claude-config\*")) {
            Remove-Item $Path -Recurse -Force
            Write-Host "  removed $Path (symlink)"
        } else {
            Write-Host "  skipped $Path (symlink points outside claude-config)"
        }
    } else {
        # Non-symlink - it's a copy install.ps1 made. Safe to remove.
        Remove-Item $Path -Recurse -Force
        Write-Host "  removed $Path (copy)"
    }
}

foreach ($cmd in @('impl.md', 'vuln.md', 'upgrade.md')) {
    Remove-IfOurs (Join-Path $ClaudeDir "commands\$cmd")
}

Remove-IfOurs (Join-Path $ClaudeDir 'plugins\workflow-tools')

# -- Hook symlinks shouldn't exist on native Windows (install.ps1 skips them),
# -- but clean up defensively in case install.sh was run via WSL2 previously.

foreach ($hook in @('notify-done.sh', 'preload-context.sh', 'test-notify.sh')) {
    $hookPath = Join-Path $ClaudeDir "hooks\$hook"
    if (Test-Path $hookPath) { Remove-IfOurs $hookPath }
}

# -- Strip hook entries from settings.json (only if Python is available) -------

$settingsPath = Join-Path $ClaudeDir 'settings.json'
$additionsPath = Join-Path $ScriptDir 'settings-additions.json'

function Test-RealPython {
    # Returns a working Python path, or $null. Guards against the Windows Store
    # python3.exe stub (a zero-byte launcher that fails at runtime).
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $out = & $cmd.Source --version 2>&1
        if ($LASTEXITCODE -eq 0) { return $cmd }
    } catch {}
    return $null
}

$pyCmd = $null
if (-not (Test-Path $settingsPath)) {
    Write-Host "  settings.json not found - nothing to clean up"
} else {
    $pyCmd = Test-RealPython 'python3'
    if (-not $pyCmd) { $pyCmd = Test-RealPython 'python' }

    if (-not $pyCmd) {
        Write-Host "  python not found (or only the Windows Store stub is present) - skipping settings.json cleanup"
        Write-Host "  (if you have installed hook entries via install.sh previously, remove them manually from $settingsPath)"
    }
}

if ($pyCmd) {
    $pyScript = @'
import sys, json

settings_path = sys.argv[1]
additions_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

with open(additions_path) as f:
    additions = json.load(f)

if "hooks" not in settings:
    print("settings.json: no hooks section - nothing to remove")
    sys.exit(0)

removed = 0
for event, entries in additions.get("hooks", {}).items():
    if event not in settings["hooks"]:
        continue
    our_cmds = set()
    our_matchers = set()
    for entry in entries:
        for h in entry.get("hooks", []):
            our_cmds.add(h["command"])
        our_matchers.add(entry.get("matcher"))

    kept = []
    for existing in settings["hooks"][event]:
        existing_cmds = {h["command"] for h in existing.get("hooks", [])}
        if existing_cmds & our_cmds and existing.get("matcher") in our_matchers:
            removed += 1
        else:
            kept.append(existing)
    if kept:
        settings["hooks"][event] = kept
    else:
        del settings["hooks"][event]

if not settings.get("hooks"):
    settings.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"settings.json: {removed} hook entr{'y' if removed == 1 else 'ies'} removed")
'@

    try {
        & $pyCmd.Source -c $pyScript $settingsPath $additionsPath
    } catch {
        Write-Host "  python execution failed: $($_.Exception.Message)"
        Write-Host "  (if you have installed hook entries via install.sh previously, remove them manually from $settingsPath)"
    }
}

Write-Host "Done."
Write-Host ""
Write-Host "The claude-config repo itself is still at $ScriptDir."
Write-Host "To delete it completely: Remove-Item -Recurse -Force '$ScriptDir'"
