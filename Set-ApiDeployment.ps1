#requires -Version 7
<#
.SYNOPSIS
    Manages Google Apps Script deployments for the backend project.

.DESCRIPTION
    Four actions are available and chosen interactively from a keyboard
    picker (Up/Down to move, Enter to select, Esc to cancel):

      1. Update API_URL in frontend/Index.html: runs `clasp deployments`,
         parses each line into DeploymentId / Version / Description and
         shows an interactive arrow-key picker. After confirmation it
         rewrites:

             const API_URL = 'https://script.google.com/macros/s/<ID>/exec';

         inside frontend/Index.html, preserving the rest of the file.

      2. Deploy a new Apps Script version: runs `clasp push` followed by
         `clasp deploy -d <description>`, then shows the resulting
         deployment (id and description) and writes it to release_info.txt.

      3. Start a local HTTP server in the frontend folder: picks a free
         port (8000-8099) and launches `python -m http.server` (or
         `npx http-server` as a fallback) in a new window so Index.html
         can be previewed in a browser.

      4. Deploy the frontend over Netlify: runs `netlify deploy --dir
         <frontend> --no-build --prod` from the repo root, then writes
         the Production URL and Unique deploy URL to release_info_netlify.txt.

    When -Description is supplied on the command line the picker is
    skipped and the deploy action runs directly.

.PARAMETER BackendPath
    Path to the clasp project folder (must contain .clasp.json).
    Defaults to "../backend" relative to this script.

.PARAMETER FrontendFile
    Path to the HTML file holding the API_URL constant.
    Defaults to "../frontend/Index.html" relative to this script.

.PARAMETER ReleaseInfoFile
    Path to the release-info file that will record the deployment id and
    description used to update the frontend. Defaults to "release_info.txt"
    in the containing folder of this script (i.e. the parent of the tools/
    folder). The file is always (re)generated and any existing file at the
    target path is overwritten.

.PARAMETER NetlifyReleaseInfoFile
    Path to the release-info file that will record the Production URL and
    Unique deploy URL produced by the Netlify deploy action. Defaults to
    "release_info_netlify.txt" in the containing folder of this script
    (i.e. the parent of the tools/ folder). The file is always
    (re)generated and any existing file at the target path is overwritten.

.PARAMETER Description
    Description for the new Apps Script deployment created by the deploy
    action. When provided the script skips the main menu and runs the
    deploy action directly.

.PARAMETER WhatIf
    If set, performs a dry-run. For the update action it lists
    deployments, lets you pick, and prints the resulting URL but never
    modifies any file. For the deploy action it prints the clasp
    commands that would run without running them. For the Netlify action
    it prints the netlify command that would run without running it.

.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -WhatIf
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -Description 'Add CSV export'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $BackendPath = (Join-Path $PSScriptRoot '..' 'backend'),
    [string] $FrontendFile = (Join-Path $PSScriptRoot '..' 'frontend' 'Index.html'),
    [string] $ReleaseInfoFile = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'release_info.txt'),
    [string] $NetlifyReleaseInfoFile = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'release_info_netlify.txt'),
    [ValidateNotNullOrEmpty()]
    [string] $Description
)

$ErrorActionPreference = 'Stop'

function Get-Deployments {
    [CmdletBinding()]
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backend path not found: $Path"
    }
    if (-not (Get-Command clasp -ErrorAction SilentlyContinue)) {
        throw "clasp CLI is not installed or not on PATH. Install with: npm i -g @google/clasp"
    }

    Push-Location -LiteralPath $Path
    try {
        $raw = & clasp deployments 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "clasp deployments failed (exit $exit):`n$raw"
    }

    $lines = @($raw | Where-Object { $_ -is [string] })
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($line in $lines) {
        # Header line: "Found N deployments." -> skip
        if ($line -match '^Found\s+\d+\s+deployment') { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Body lines look like: "- <DEPLOYMENT_ID> @<VERSION>[ - <DESCRIPTION>]"
        # Description is optional; @HEAD lines have no description. ID is the first token after "- ".
        if ($line -notmatch '^-\s+(?<id>\S+)\s+@(?<ver>\S+)(?:\s+-\s*(?<desc>.*))?\s*$') {
            Write-Warning "Skipping unrecognized line: $line"
            continue
        }
        $items.Add([pscustomobject]@{
            Id          = $matches['id']
            Version     = $matches['ver']
            Description = if ($matches['desc']) { $matches['desc'].Trim() } else { '' }
            Url         = "https://script.google.com/macros/s/$($matches['id'])/exec"
        })
    }
    return ,$items
}

function Get-DeploymentsJson {
    [CmdletBinding()]
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backend path not found: $Path"
    }
    if (-not (Get-Command clasp -ErrorAction SilentlyContinue)) {
        throw "clasp CLI is not installed or not on PATH. Install with: npm i -g @google/clasp"
    }

    Push-Location -LiteralPath $Path
    try {
        $raw = & clasp list-deployments --json 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "clasp list-deployments failed (exit $exit):`n$raw"
    }

    # clasp may emit the JSON as a single string or across multiple lines
    # (when stderr is merged via 2>&1). Stitch it back together.
    $jsonText = ($raw | Where-Object { $_ -is [string] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return @()
    }

    $parsed = $jsonText | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $parsed) {
        return @()
    }

    # JSON shape may be a flat array OR an object with a "deployments" array;
    # clasp has shipped both across releases.
    if ($parsed -is [pscustomobject] -and $parsed.PSObject.Properties['deployments']) {
        $list = @($parsed.deployments)
    } else {
        $list = @($parsed)
    }
    if ($list.Count -eq 0) {
        return @()
    }

    $items = foreach ($entry in $list) {
        if ($null -eq $entry) { continue }

        # Property names have varied across clasp releases. Probe each
        # candidate and take the first one that actually exists.
        $id = $entry.deploymentId
        if ($null -eq $id) { $id = $entry.id }
        if ($null -eq $id) { $id = $entry.deployment_id }
        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $desc = $entry.description
        if ($null -eq $desc) { $desc = $entry.desc }
        if ($null -eq $desc) { $desc = '' }

        $ver = $entry.versionNumber
        if ($null -eq $ver) { $ver = $entry.version_number }
        if ($null -eq $ver) { $ver = $entry.version }

        [pscustomobject]@{
            DeploymentId  = [string] $id
            Description   = [string] $desc
            VersionNumber = $ver   # $null for @HEAD entries
            Url           = "https://script.google.com/macros/s/$id/exec"
        }
    }
    return ,@($items)
}

function Get-LatestDeployment {
    [CmdletBinding()]
    param([string] $Path)

    # Always normalize to a single shape so the caller can rely on
    # DeploymentId / VersionNumber / Description regardless of which
    # clasp command produced the data.
    $normalized = New-Object System.Collections.Generic.List[object]

    # Preferred path: `clasp list-deployments --json` (clasp 3.x).
    # If it works we get structured {deploymentId, versionNumber, description}.
    try {
        $jsonItems = @(Get-DeploymentsJson -Path $Path)
        foreach ($item in $jsonItems) {
            $ver = $item.VersionNumber
            $normalized.Add([pscustomobject]@{
                DeploymentId  = [string] $item.DeploymentId
                VersionNumber = if ($null -eq $ver) { $null } else { [int]$ver }
                Description   = if ($null -eq $item.Description) { '' } else { [string]$item.Description }
            })
        }
    }
    catch {
        Write-Verbose ("JSON listing failed: {0}" -f $_.Exception.Message)
    }

    # Fallback: text-mode `clasp deployments` (works on clasp 2.x and any
    # environment where --json is not supported or returns nothing useful).
    if ($normalized.Count -eq 0) {
        try {
            $textItems = @(Get-Deployments -Path $Path)
            foreach ($item in $textItems) {
                $verStr = [string] $item.Version
                $ver = if ($verStr -match '^\d+$') { [int]$verStr } else { $null }
                $normalized.Add([pscustomobject]@{
                    DeploymentId  = [string] $item.Id
                    VersionNumber = $ver
                    Description   = if ($null -eq $item.Description) { '' } else { [string]$item.Description }
                })
            }
        }
        catch {
            Write-Verbose ("Text listing failed: {0}" -f $_.Exception.Message)
        }
    }

    if ($normalized.Count -eq 0) {
        return $null
    }

    # @HEAD has VersionNumber == $null. Prefer the highest real version,
    # but if only @HEAD exists show it so the user sees something useful.
    $numbered = @($normalized | Where-Object { $null -ne $_.VersionNumber })
    if ($numbered.Count -gt 0) {
        return @($numbered | Sort-Object -Property VersionNumber -Descending)[0]
    }
    return $normalized[0]
}

function Show-Picker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Items,
        [string] $Title = 'Select a deployment'
    )

    if ($Items.Count -eq 0) {
        Write-Host "No deployments found." -ForegroundColor Red
        return $null
    }

    $sel = 0
    $top = [Console]::CursorTop
    $hostUi = $Host.UI.RawUI

    # The picker renders 3 header lines plus one row per item plus one
    # trailing cursor position. When the cursor is already near the
    # bottom of a small console, SetCursorPosition calls would throw
    # "must be less than the buffer size". Clamp $top so every row we
    # touch stays inside the buffer.
    $rowsNeeded = 3 + $Items.Count + 1
    $maxTop = [Math]::Max(0, $hostUi.BufferHeight - $rowsNeeded)
    $top = [Math]::Min($top, $maxTop)

    function Render {
        param($Items, [int] $Sel, [int] $Top, [string] $Title)
        # Move to the saved top line and redraw the menu from there.
        [Console]::SetCursorPosition(0, $Top)
        $width = [Math]::Max(20, $hostUi.BufferWidth - 1)
        $clearLine = (' ' * $width)

        Write-Host ("{0}" -f $Title) -ForegroundColor Cyan
        Write-Host ("Use Up/Down to move, Enter to select, Esc to cancel, Home/End to jump.")
        Write-Host ''
        for ($i = 0; $i -lt $Items.Count; $i++) {
            [Console]::SetCursorPosition(0, $Top + 3 + $i)
            Write-Host $clearLine -NoNewline
            [Console]::SetCursorPosition(0, $Top + 3 + $i)
            $prefix = if ($i -eq $Sel) { '> ' } else { '  ' }
            $id = $Items[$i].Id
            $ver = $Items[$i].Version
            $desc = $Items[$i].Description
            $row = "$prefix$ver  $id  $desc"
            if ($i -eq $Sel) {
                Write-Host $row -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $row
            }
        }
        # Reset colors so the next plain Write-Host doesn't inherit the highlight background.
        [Console]::ResetColor()
        [Console]::SetCursorPosition(0, $Top + 3 + $Items.Count)
    }

    Render -Items $Items -Sel $sel -Top $top -Title $Title
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'    { $sel = ($sel - 1 + $Items.Count) % $Items.Count }
                'DownArrow'  { $sel = ($sel + 1) % $Items.Count }
                'Home'       { $sel = 0 }
                'End'        { $sel = $Items.Count - 1 }
                'Enter'      { return $Items[$sel] }
                'Escape'     { return $null }
                default      { continue }
            }
            Render -Items $Items -Sel $sel -Top $top -Title $Title
        }
    }
    finally {
        # Wipe the whole screen so no picker artifacts (cursor positions,
        # leftover colored backgrounds, partial lines) survive into the rest
        # of the script or the user's shell. Clear-Host is the canonical
        # PowerShell way to do this and works on both Windows Terminal and
        # the classic console host.
        [Console]::ResetColor()
        Clear-Host
        [Console]::SetCursorPosition(0, 0)
    }
}

function Show-MainMenu {
    # Top-level action picker. Returns the chosen action key
    # ('Update', 'Deploy', 'Localhost' or 'Netlify') or $null if the user cancels.
    $options = @(
        [pscustomobject]@{ Key = 'Update';    Label = 'Update API_URL in Index.html' }
        [pscustomobject]@{ Key = 'Deploy';    Label = 'Deploy a new Apps Script version' }
        [pscustomobject]@{ Key = 'Localhost'; Label = 'Start a local HTTP server in the frontend folder' }
        [pscustomobject]@{ Key = 'Netlify';   Label = 'Deploy the frontend over Netlify' }
    )

    $sel = 0
    $top = [Console]::CursorTop
    $hostUi = $Host.UI.RawUI

    # Same buffer-height clamp as Show-Picker: ensure every row we touch
    # is inside the console buffer so SetCursorPosition does not throw.
    $rowsNeeded = 3 + $options.Count + 1
    $maxTop = [Math]::Max(0, $hostUi.BufferHeight - $rowsNeeded)
    $top = [Math]::Min($top, $maxTop)

    function Render {
        param($Opts, [int] $Sel, [int] $Top)
        [Console]::SetCursorPosition(0, $Top)
        $width = [Math]::Max(20, $hostUi.BufferWidth - 1)
        $clearLine = ' ' * $width

        Write-Host 'Choose an action:' -ForegroundColor Cyan
        Write-Host 'Use Up/Down to move, Enter to select, Esc to cancel.'
        Write-Host ''
        for ($i = 0; $i -lt $Opts.Count; $i++) {
            [Console]::SetCursorPosition(0, $Top + 3 + $i)
            Write-Host $clearLine -NoNewline
            [Console]::SetCursorPosition(0, $Top + 3 + $i)
            $prefix = if ($i -eq $Sel) { '> ' } else { '  ' }
            $row = "$prefix$($Opts[$i].Label)"
            if ($i -eq $Sel) {
                Write-Host $row -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $row
            }
        }
        [Console]::ResetColor()
        [Console]::SetCursorPosition(0, $Top + 3 + $Opts.Count)
    }

    Render -Opts $options -Sel $sel -Top $top
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $options.Count) % $options.Count }
                'DownArrow' { $sel = ($sel + 1) % $options.Count }
                'Enter'     { return $options[$sel].Key }
                'Escape'    { return $null }
                default     { continue }
            }
            Render -Opts $options -Sel $sel -Top $top
        }
    }
    finally {
        [Console]::ResetColor()
        Clear-Host
        [Console]::SetCursorPosition(0, 0)
    }
}

function Set-ApiUrlInFile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $File,
        [Parameter(Mandatory)] [string] $Url
    )

    if (-not (Test-Path -LiteralPath $File)) {
        throw "Frontend file not found: $File"
    }
    $content = Get-Content -LiteralPath $File -Raw -Encoding UTF8
    $pattern = "(const\s+API_URL\s*=\s*')(.*?)(';)"
    if ($content -notmatch $pattern) {
        throw "Could not locate 'const API_URL = '...';' in $File"
    }
    $newLine = "$($matches[1])$Url$($matches[3])"
    $newContent = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{
        param($m) "$($m.Groups[1].Value)$Url$($m.Groups[3].Value)"
    }, 1)

    if ($PSCmdlet.ShouldProcess($File, "Update API_URL to $Url")) {
        # Write back as UTF-8 without BOM to preserve the file's existing encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Resolve-Path -LiteralPath $File).Path, $newContent, $utf8NoBom)
    }
}

function Start-LocalhostServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $FrontendPath)

    if (-not (Test-Path -LiteralPath $FrontendPath)) {
        throw "Frontend folder not found: $FrontendPath"
    }

    # Find a free port, starting at 8000 and walking up to 8099.
    $port = $null
    for ($p = 8000; $p -lt 8100; $p++) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
            $listener.Start()
            $port = $p
            break
        }
        catch {
            continue
        }
        finally {
            if ($listener) {
                try { $listener.Stop() } catch { }
            }
        }
    }
    if (-not $port) {
        throw "Could not find an available port in the range 8000-8099."
    }

    # Prefer Python 3's built-in http.server; fall back to npx http-server.
    $serverCmd = $null
    $serverArgs = @()
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $serverCmd = 'python'
        $serverArgs = @('-m', 'http.server', $port)
    }
    elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
        $serverCmd = 'python3'
        $serverArgs = @('-m', 'http.server', $port)
    }
    elseif (Get-Command npx -ErrorAction SilentlyContinue) {
        $serverCmd = 'npx'
        $serverArgs = @('http-server', '.', '-p', "$port", '-c-1')
    }

    if (-not $serverCmd) {
        throw "No HTTP server tool found. Install Python 3 (or Node.js for npx http-server)."
    }

    Write-Host ''
    Write-Host ("Frontend folder : {0}" -f $FrontendPath)
    Write-Host ("URL            : http://localhost:{0}/" -f $port)
    Write-Host ("Command        : {0} {1}" -f $serverCmd, ($serverArgs -join ' '))
    Write-Host ''

    if ($WhatIfPreference) {
        Write-Host "[WhatIf] Would launch the server in a new window. Stop it with Ctrl+C in that window." -ForegroundColor DarkGray
        return
    }

    # Launch in a new console window so the user can see server logs and
    # stop the server with Ctrl+C without blocking this script.
    Start-Process -FilePath $serverCmd -ArgumentList $serverArgs -WorkingDirectory $FrontendPath

    # Give the server a moment to bind, then open the default browser.
    Start-Sleep -Milliseconds 750
    try {
        Start-Process -FilePath ("http://localhost:{0}/" -f $port) -ErrorAction SilentlyContinue
    }
    catch {
        # Browser open is best-effort; ignore failures (e.g. headless env).
    }
}

function Write-ReleaseInfo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $File,
        [Parameter(Mandatory)] $Deployment
    )

    $content = @"
# Released deployment
DeploymentId : $($Deployment.Id)
Version      : $($Deployment.Version)
Description  : $($Deployment.Description)
Url          : $($Deployment.Url)
"@

    if (-not $PSCmdlet.ShouldProcess($File, "Write release info")) {
        return
    }

    # Resolve the target to an absolute path anchored at the containing
    # folder of the tools/ directory when the caller did not override it.
    $resolvedFile = if ([System.IO.Path]::IsPathRooted($File)) {
        $File
    } else {
        Join-Path (Split-Path -Path $PSScriptRoot -Parent) $File
    }

    # Ensure the parent directory exists. The containing folder of tools/
    # normally already exists, but creating it is cheap and avoids races
    # when the script is run from a fresh clone.
    $dir = Split-Path -Path $resolvedFile -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
    }

    # [System.IO.File]::WriteAllText creates the file when it does not exist
    # and overwrites it when it does. We want unconditional regeneration:
    # any prior release_info.txt in the containing folder of tools is
    # replaced with the freshly selected deployment. Failures here are
    # surfaced to the caller (no try/catch) so the script does not silently
    # report success while leaving stale info behind.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedFile, $content, $utf8NoBom)
}

function Write-NetlifyReleaseInfo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $File,
        [Parameter(Mandatory)] $Deployment
    )

    $content = @"
# Netlify deployment
ProductionUrl : $($Deployment.ProductionUrl)
UniqueUrl     : $($Deployment.UniqueUrl)
"@

    if (-not $PSCmdlet.ShouldProcess($File, "Write Netlify release info")) {
        return
    }

    # Resolve a relative path against the containing folder of the tools/
    # directory so the file lands next to release_info.txt in the repo root.
    $resolvedFile = if ([System.IO.Path]::IsPathRooted($File)) {
        $File
    } else {
        Join-Path (Split-Path -Path $PSScriptRoot -Parent) $File
    }

    $dir = Split-Path -Path $resolvedFile -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -LiteralPath $dir -Force | Out-Null
    }

    # Always overwrite. Failures propagate so the script does not silently
    # report success while leaving stale info behind.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedFile, $content, $utf8NoBom)
}

function Invoke-PushDeployment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Description
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backend path not found: $Path"
    }
    if (-not (Get-Command clasp -ErrorAction SilentlyContinue)) {
        throw "clasp CLI is not installed or not on PATH. Install with: npm i -g @google/clasp"
    }

    # Step 1: push local backend files to Apps Script.
    if (-not $PSCmdlet.ShouldProcess("$Path (clasp push)", 'Push backend files')) {
        Write-Host "[WhatIf] Would run: clasp push in $Path" -ForegroundColor DarkGray
    } else {
        Push-Location -LiteralPath $Path
        try {
            $pushOut = & clasp push 2>&1
            $pushExit = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
        if ($pushExit -ne 0) {
            throw "clasp push failed (exit $pushExit):`n$pushOut"
        }
        Write-Host "Pushed backend files from $Path" -ForegroundColor Green
    }

    # Step 2: create a new deployment with the given description.
    if (-not $PSCmdlet.ShouldProcess("$Path (clasp deploy -d '$Description')", 'Deploy new version')) {
        Write-Host "[WhatIf] Would run: clasp deploy -d '$Description' in $Path" -ForegroundColor DarkGray
        return $null
    }

    Push-Location -LiteralPath $Path
    try {
        $deployOut = & clasp deploy -d $Description 2>&1
        $deployExit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($deployExit -ne 0) {
        throw "clasp deploy failed (exit $deployExit):`n$deployOut"
    }

    # Echo clasp's own output so the user sees what happened, then parse the
    # new deployment id from the trailing "- <id> @<ver> - <desc>" line.
    foreach ($line in @($deployOut | Where-Object { $_ -is [string] })) {
        Write-Host $line
    }

    $newDep = $null
    foreach ($line in @($deployOut | Where-Object { $_ -is [string] })) {
        if ($line -match '^-\s+(?<id>\S+)\s+@(?<ver>\S+)(?:\s+-\s*(?<desc>.*))?\s*$') {
            $newDep = [pscustomobject]@{
                Id          = $matches['id']
                Version     = $matches['ver']
                Description = if ($matches['desc']) { $matches['desc'].Trim() } else { '' }
                Url         = "https://script.google.com/macros/s/$($matches['id'])/exec"
            }
            break
        }
    }

    if (-not $newDep) {
        Write-Warning "clasp deploy succeeded but no deployment line was found in its output."
    }
    return $newDep
}

function Invoke-NetlifyDeploy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Frontend folder not found: $Path"
    }
    if (-not (Get-Command netlify -ErrorAction SilentlyContinue)) {
        throw "netlify CLI is not installed or not on PATH. Install with: npm i -g netlify-cli"
    }

    # Run from the repo root so Netlify picks up netlify.toml / .netlify/state.json
    # if they exist. The --dir argument gets the absolute frontend path so it
    # resolves correctly regardless of the caller's working directory.
    $absFrontend = (Resolve-Path -LiteralPath $Path).Path
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $cmd = @('deploy', '--dir', $absFrontend, '--no-build', '--prod')

    if (-not $PSCmdlet.ShouldProcess("$repoRoot (netlify $($cmd -join ' '))", 'Netlify deploy')) {
        Write-Host ("[WhatIf] Would run: netlify {0} in {1}" -f ($cmd -join ' '), $repoRoot) -ForegroundColor DarkGray
        return $null
    }

    Push-Location -LiteralPath $repoRoot
    try {
        $raw = & netlify @cmd 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "netlify deploy failed (exit $exit):`n$raw"
    }

    # Echo netlify's output so the user sees what happened.
    foreach ($line in @($raw | Where-Object { $_ -is [string] })) {
        Write-Host $line
    }

    # Parse the two URL lines netlify prints on success. Either may be missing
    # in older versions or custom output formats, so neither is fatal.
    $productionUrl = $null
    $uniqueUrl = $null
    foreach ($line in @($raw | Where-Object { $_ -is [string] })) {
        if ($null -eq $productionUrl -and $line -match '^Production URL:\s+(?<url>\S+)') {
            $productionUrl = $matches['url']
        }
        elseif ($null -eq $uniqueUrl -and $line -match '^Unique deploy URL:\s+(?<url>\S+)') {
            $uniqueUrl = $matches['url']
        }
    }

    if (-not $productionUrl -and -not $uniqueUrl) {
        Write-Warning "netlify deploy succeeded but no 'Production URL:' / 'Unique deploy URL:' line was found in its output."
    }

    return [pscustomobject]@{
        ProductionUrl = $productionUrl
        UniqueUrl     = $uniqueUrl
        Raw           = ($raw -join "`n")
    }
}

try {
    # Decide the action up front. Supplying -Description on the command line
    # skips the picker and runs the deploy action directly.
    if ($Description) {
        $mode = 'Deploy'
    } else {
        $mode = Show-MainMenu
        if (-not $mode) {
            Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
            exit 2
        }
    }

    switch ($mode) {
        'Update' {
            $items = Get-Deployments -Path $BackendPath
            if (-not $items -or $items.Count -eq 0) {
                Write-Host "No deployments available for $BackendPath." -ForegroundColor Yellow
                exit 1
            }

            if ($items.Count -eq 1) {
                $choice = $items[0]
                Write-Host ("Only one deployment found, using {0} ({1})." -f $choice.Version, $choice.Id) -ForegroundColor Yellow
            } else {
                $choice = Show-Picker -Items $items -Title "Apps Script deployments ($BackendPath)"
                if (-not $choice) {
                    Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
                    exit 2
                }
            }

            Write-Host ''
            Write-Host ("Selected : {0}" -f $choice.Id) -ForegroundColor Green
            Write-Host ("Version  : {0}" -f $choice.Version) -ForegroundColor Green
            Write-Host ("Desc     : {0}" -f $choice.Description) -ForegroundColor Green
            Write-Host ("URL      : {0}" -f $choice.Url) -ForegroundColor Green
            Write-Host ''

            Set-ApiUrlInFile -File $FrontendFile -Url $choice.Url
            Write-Host "Updated API_URL in $FrontendFile" -ForegroundColor Green

            Write-ReleaseInfo -File $ReleaseInfoFile -Deployment $choice
            Write-Host "Wrote release info to $ReleaseInfoFile" -ForegroundColor Green
        }
        'Deploy' {
            # Show the latest deployment before asking for a new description,
            # so the user knows what is currently out there. @HEAD is
            # skipped and the highest versionNumber wins, via clasp's JSON
            # output (more reliable than the text format).
            try {
                $latest = Get-LatestDeployment -Path $BackendPath
                Write-Host ''
                if ($latest) {
                    Write-Host 'Current latest deployment:' -ForegroundColor Cyan
                    Write-Host ("  Id          : {0}" -f $latest.DeploymentId)
                    Write-Host ("  Version     : {0}" -f $latest.VersionNumber)
                    Write-Host ("  Description : {0}" -f $latest.Description)
                } else {
                    Write-Host 'No existing deployments yet (this will be the first).' -ForegroundColor Yellow
                }
                Write-Host ''
            }
            catch {
                # Don't block the deploy just because listing failed; the
                # push/deploy calls below will surface a clearer error if
                # something is actually wrong with the backend setup.
                Write-Warning ("Could not list current deployments: {0}" -f $_.Exception.Message)
            }

            # When we got here through the menu, $Description is unset; ask
            # for it interactively. When -Description was passed on the
            # command line it has already been validated non-empty.
            if ([string]::IsNullOrWhiteSpace($Description)) {
                $Description = Read-Host 'Enter a description for the new deployment'
                if ([string]::IsNullOrWhiteSpace($Description)) {
                    throw 'Description cannot be empty.'
                }
            }

            $newDep = Invoke-PushDeployment -Path $BackendPath -Description $Description
            if ($newDep) {
                Write-Host ''
                Write-Host ("New deployment : {0}" -f $newDep.Id) -ForegroundColor Green
                Write-Host ("Version        : {0}" -f $newDep.Version) -ForegroundColor Green
                Write-Host ("Description    : {0}" -f $newDep.Description) -ForegroundColor Green
                Write-Host ("URL            : {0}" -f $newDep.Url) -ForegroundColor Green
                Write-Host ''

                Write-ReleaseInfo -File $ReleaseInfoFile -Deployment $newDep
                Write-Host "Wrote release info to $ReleaseInfoFile" -ForegroundColor Green
            }
        }
        'Localhost' {
            $frontendFolder = Split-Path -Path $FrontendFile -Parent
            Start-LocalhostServer -FrontendPath $frontendFolder
        }
        'Netlify' {
            $frontendFolder = Split-Path -Path $FrontendFile -Parent
            $result = Invoke-NetlifyDeploy -Path $frontendFolder
            if ($result) {
                Write-Host ''
                if ($result.ProductionUrl) {
                    Write-Host ("Production URL : {0}" -f $result.ProductionUrl) -ForegroundColor Green
                }
                if ($result.UniqueUrl) {
                    Write-Host ("Unique URL     : {0}" -f $result.UniqueUrl) -ForegroundColor Green
                }
                Write-Host ''

                Write-NetlifyReleaseInfo -File $NetlifyReleaseInfoFile -Deployment $result
                Write-Host "Wrote Netlify release info to $NetlifyReleaseInfoFile" -ForegroundColor Green
            }
        }
    }
}
catch {
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
