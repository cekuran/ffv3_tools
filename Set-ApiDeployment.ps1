#requires -Version 7
<#
.SYNOPSIS
    Manages Google Apps Script deployments for the backend project.

.DESCRIPTION
    Six actions are available and chosen interactively from a keyboard
    picker (Up/Down to move, Enter to select, Esc to cancel). After every
    action except Exit, the script pauses and shows the menu again so you
    can chain multiple actions in a single run:

      1. Update API_URL in frontend/Index.html: runs `clasp deployments`,
         parses each line into DeploymentId / Version / Description and
         shows an interactive arrow-key picker. After confirmation it
         rewrites:

             const API_URL = 'https://script.google.com/macros/s/<ID>/exec';

         inside frontend/Index.html, preserving the rest of the file.

      2. Deploy a new Apps Script version: runs `clasp push` followed by
         `clasp deploy -d <description>`, then shows the resulting
         deployment (id and description) and writes it to release_info.txt.

      3. Undeploy an Apps Script deployment: lists current deployments,
         shows an interactive picker, and runs `clasp undeploy <id>` after
         a typed confirmation. The frontend API_URL may still point to the
         removed deployment afterwards and will need to be updated with
         action 1.

      4. Start a local HTTP server in the frontend folder: picks a free
         port (8000-8099) and launches `python -m http.server` (or
         `npx http-server` as a fallback) in a new window so Index.html
         can be previewed in a browser.

      5. Deploy the frontend over Netlify: runs `netlify deploy --dir
         <frontend> --no-build --prod` from the repo root, then writes
         the Production URL and Unique deploy URL to release_info_netlify.txt.

      6. Exit the script.

    When -Description, -UndeployId, or -UndeployAll is supplied on the
    command line the picker is skipped and the matching action runs
    directly without confirmation.

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

.PARAMETER UndeployId
    Deployment ID to undeploy. When provided (and -UndeployAll is not)
    the script skips the main menu and runs the undeploy action directly
    without the typed confirmation prompt. Cannot be combined with
    -UndeployAll.

.PARAMETER UndeployAll
    When set, undeploys every Apps Script deployment. When provided (and
    -UndeployId is not) the script skips the main menu and runs the
    undeploy action directly without the typed confirmation prompt.
    Cannot be combined with -UndeployId.

.PARAMETER WhatIf
    If set, performs a dry-run. For the update action it lists
    deployments, lets you pick, and prints the resulting URL but never
    modifies any file. For the deploy action it prints the clasp
    commands that would run without running them. For the undeploy action
    it lists deployments, lets you pick, and prints the clasp undeploy
    command that would run without running it. For the Netlify action
    it prints the netlify command that would run without running it.

.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -WhatIf
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -Description 'Add CSV export'
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -UndeployId 'AKfycbx...'
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -UndeployAll
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $BackendPath = (Join-Path $PSScriptRoot '..' 'backend'),
    [string] $FrontendFile = (Join-Path $PSScriptRoot '..' 'frontend' 'Index.html'),
    [string] $ReleaseInfoFile = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'release_info.txt'),
    [string] $NetlifyReleaseInfoFile = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'release_info_netlify.txt'),
    [ValidateNotNullOrEmpty()]
    [string] $Description,
    [ValidateNotNullOrEmpty()]
    [string] $UndeployId,
    [switch] $UndeployAll
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

    try {
        $jsonItems = @(Get-DeploymentsJson -Path $Path)
        if ($jsonItems.Count -gt 0) {
            return @(
                $jsonItems | ForEach-Object {
                    [pscustomobject]@{
                        Id          = [string] $_.DeploymentId
                        Version     = if ($null -eq $_.VersionNumber) { '' } else { [string] $_.VersionNumber }
                        Description = if ($null -eq $_.Description) { '' } else { [string] $_.Description }
                        Url         = "https://script.google.com/macros/s/$([string] $_.DeploymentId)/exec"
                    }
                }
            )
        }
    }
    catch {
        Write-Verbose ("JSON listing failed: {0}" -f $_.Exception.Message)
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
        $cleanLine = [regex]::Replace([string]$line, '\x1B\[[0-9;]*[A-Za-z]', '')
        # Header line: "Found N deployments." -> skip
        if ($cleanLine -match '^Found\s+\d+\s+deployment') { continue }
        if ([string]::IsNullOrWhiteSpace($cleanLine)) { continue }
        # Body lines look like: "- <DEPLOYMENT_ID> @<VERSION>[ - <DESCRIPTION>]"
        # Description is optional; @HEAD lines have no description. ID is the first token after "- ".
        if ($cleanLine -notmatch '^-\s+(?<id>\S+)\s+@(?<ver>\S+)(?:\s+-\s*(?<desc>.*))?\s*$') {
            Write-Warning "Skipping unrecognized line: $cleanLine"
            continue
        }
        $items.Add([pscustomobject]@{
            Id          = $matches['id']
            Version     = $matches['ver']
            Description = if ($matches['desc']) { $matches['desc'].Trim() } else { '' }
            Url         = "https://script.google.com/macros/s/$($matches['id'])/exec"
        })
    }
    return @($items)
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
    return @($items)
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

    function Render {
        param($Items, [int] $Sel, [string] $Title)
        # Full-screen redraw is more robust across VS Code terminals than
        # cursor repositioning with SetCursorPosition.
        Clear-Host
        Write-Host ("{0}" -f $Title) -ForegroundColor Cyan
        Write-Host ("Use Up/Down to move, Enter to select, Esc to cancel, Home/End to jump.")
        Write-Host ''
        for ($i = 0; $i -lt $Items.Count; $i++) {
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
        # Reset colors so the next plain Write-Host doesn't inherit highlight background.
        [Console]::ResetColor()
    }

    Render -Items $Items -Sel $sel -Title $Title
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
            Render -Items $Items -Sel $sel -Title $Title
        }
    }
    finally {
        # Wipe the whole screen so no picker artifacts survive into the shell.
        [Console]::ResetColor()
        Clear-Host
    }
}

function Show-MainMenu {
    # Top-level action picker. Returns the chosen action key
    # ('Update', 'Deploy', 'Undeploy', 'Localhost', 'Netlify' or 'Exit') or $null if the user cancels.
    $options = @(
        [pscustomobject]@{ Key = 'Update';    Label = 'Update API_URL in Index.html' }
        [pscustomobject]@{ Key = 'Deploy';    Label = 'Deploy a new Apps Script version' }
        [pscustomobject]@{ Key = 'Undeploy';  Label = 'Undeploy an Apps Script deployment' }
        [pscustomobject]@{ Key = 'Localhost'; Label = 'Start a local HTTP server in the frontend folder' }
        [pscustomobject]@{ Key = 'Netlify';   Label = 'Deploy the frontend over Netlify' }
        [pscustomobject]@{ Key = 'Exit';      Label = 'Exit the script' }
    )
    $choice = Show-ListPicker -Options $options -Title 'Choose an action:'
    if ($choice) { $choice.Key } else { $null }
}

function Show-ListPicker {
    # Arrow-key picker over a labeled list. Used by Show-MainMenu and any
    # action case that needs a sub-menu. Returns the chosen option object
    # or $null if the user cancels.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Options,
        [string] $Title = 'Select an option'
    )

    $sel = 0

    function Render {
        param($Options, [int] $Sel, [string] $Title)
        Clear-Host
        Write-Host ("{0}" -f $Title) -ForegroundColor Cyan
        Write-Host 'Use Up/Down to move, Enter to select, Esc to cancel.'
        Write-Host ''
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $prefix = if ($i -eq $Sel) { '> ' } else { '  ' }
            $row = "$prefix$($Options[$i].Label)"
            if ($i -eq $Sel) {
                Write-Host $row -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host $row
            }
        }
        [Console]::ResetColor()
    }

    Render -Options $Options -Sel $sel -Title $Title
    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            switch ($key.Key) {
                'UpArrow'   { $sel = ($sel - 1 + $Options.Count) % $Options.Count }
                'DownArrow' { $sel = ($sel + 1) % $Options.Count }
                'Enter'     { return $Options[$sel] }
                'Escape'    { return $null }
                default     { continue }
            }
            Render -Options $Options -Sel $sel -Title $Title
        }
    }
    finally {
        [Console]::ResetColor()
        Clear-Host
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

function Clear-ReleaseInfo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $File,
        [string] $DeploymentId
    )

    # Resolve relative paths against the parent of tools/ (where
    # release_info.txt lives), matching the write-side helpers.
    $resolvedFile = if ([System.IO.Path]::IsPathRooted($File)) {
        $File
    } else {
        Join-Path (Split-Path -Path $PSScriptRoot -Parent) $File
    }
    if (-not (Test-Path -LiteralPath $resolvedFile)) {
        return
    }

    # If a DeploymentId is given, only delete when the file references
    # that specific deployment. Without it (e.g. -UndeployAll) the file
    # is unconditionally stale and removed.
    if ($DeploymentId) {
        $content = Get-Content -LiteralPath $resolvedFile -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($content)) { return }
        if ($content -notmatch '(?m)^DeploymentId\s*:\s*(?<id>\S+)\s*$') { return }
        if ($matches['id'] -ne $DeploymentId) { return }
    }

    if ($PSCmdlet.ShouldProcess($resolvedFile, 'Remove stale release info')) {
        Remove-Item -LiteralPath $resolvedFile -Force
    }
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

    # Parse only deployment rows and keep the newest one. Output formats vary:
    #   - "- <id> @<ver> - <desc>"
    #   - "Deployed <id> @<ver>"
    $parsedDeps = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($deployOut | Where-Object { $_ -is [string] })) {
        $cleanLine = [regex]::Replace([string]$line, '\x1B\[[0-9;]*[A-Za-z]', '')
        if (
            ($cleanLine -match '^-\s+(?<id>\S+)\s+@(?<ver>\S+)(?:\s+-\s*(?<desc>.*))?\s*$') -or
            ($cleanLine -match '^Deployed\s+(?<id>\S+)\s+@(?<ver>\S+)\s*$')
        ) {
            $verText = $matches['ver']
            $verNum = if ($verText -match '^\d+$') { [int]$verText } else { $null }
            $descText = if ($matches['desc']) { $matches['desc'].Trim() } else { '' }
            if ([string]::IsNullOrWhiteSpace($descText)) {
                $descText = $Description
            }
            $parsedDeps.Add([pscustomobject]@{
                Id          = $matches['id']
                Version     = $verText
                VersionNum  = $verNum
                Description = $descText
                Url         = "https://script.google.com/macros/s/$($matches['id'])/exec"
            })
        }
    }

    $newDep = $null
    if ($parsedDeps.Count -gt 0) {
        $withVersion = @($parsedDeps | Where-Object { $null -ne $_.VersionNum })
        if ($withVersion.Count -gt 0) {
            $newDep = @($withVersion | Sort-Object -Property VersionNum -Descending)[0]
        } else {
            # Fallback when only non-numeric versions exist (for example @HEAD).
            $newDep = @($parsedDeps)[-1]
        }

        # Some clasp output variants can miss the id token while still
        # reporting the version. Backfill from the actual latest deployment.
        if ([string]::IsNullOrWhiteSpace([string]$newDep.Id)) {
            $latest = Get-LatestDeployment -Path $Path
            if ($latest -and -not [string]::IsNullOrWhiteSpace([string]$latest.DeploymentId)) {
                $newDep.Id = [string] $latest.DeploymentId
                if ($null -eq $newDep.VersionNum -and $null -ne $latest.VersionNumber) {
                    $newDep.Version = [string] $latest.VersionNumber
                    $newDep.VersionNum = [int] $latest.VersionNumber
                }
                $newDep.Url = "https://script.google.com/macros/s/$($newDep.Id)/exec"
            }
        }

        Write-Host ("Created deployment: {0} @{1}" -f $newDep.Id, $newDep.Version) -ForegroundColor Green
    }

    if (-not $newDep) {
        # Last-resort fallback: ask clasp for the latest deployment after a
        # successful deploy, then map it to the shape expected by callers.
        $latest = Get-LatestDeployment -Path $Path
        if ($latest) {
            $newDep = [pscustomobject]@{
                Id          = [string] $latest.DeploymentId
                Version     = if ($null -eq $latest.VersionNumber) { '@HEAD' } else { [string] $latest.VersionNumber }
                VersionNum  = if ($null -eq $latest.VersionNumber) { $null } else { [int] $latest.VersionNumber }
                Description = if ([string]::IsNullOrWhiteSpace([string] $latest.Description)) { $Description } else { [string] $latest.Description }
                Url         = "https://script.google.com/macros/s/$($latest.DeploymentId)/exec"
            }
            Write-Host ("Created deployment: {0} @{1}" -f $newDep.Id, $newDep.Version) -ForegroundColor Green
        } else {
            Write-Warning "clasp deploy succeeded but no deployment line was found in its output."
        }
    }
    return $newDep
}

function Invoke-Undeploy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $DeploymentId,
        [switch] $All
    )

    if ($All -and $DeploymentId) {
        throw "Specify either -DeploymentId or -All, not both."
    }
    if (-not $All -and [string]::IsNullOrWhiteSpace($DeploymentId)) {
        throw "Specify either -DeploymentId or -All."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Backend path not found: $Path"
    }
    if (-not (Get-Command clasp -ErrorAction SilentlyContinue)) {
        throw "clasp CLI is not installed or not on PATH. Install with: npm i -g @google/clasp"
    }

    $claspArgs = if ($All) { @('--all') } else { @($DeploymentId) }
    $argDisplay = $claspArgs -join ' '

    if (-not $PSCmdlet.ShouldProcess("$Path (clasp undeploy $argDisplay)", 'Undeploy deployment')) {
        Write-Host ("[WhatIf] Would run: clasp undeploy $argDisplay in $Path") -ForegroundColor DarkGray
        return
    }

    Push-Location -LiteralPath $Path
    try {
        $raw = & clasp undeploy @claspArgs 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exit -ne 0) {
        throw "clasp undeploy failed (exit $exit):`n$raw"
    }
    foreach ($line in @($raw | Where-Object { $_ -is [string] })) {
        Write-Host $line
    }
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
    # Validate mutual exclusivity first.
    if ($UndeployAll -and $UndeployId) {
        throw "Cannot specify both -UndeployAll and -UndeployId."
    }

    # CLI params: single-shot mode (run once, exit). Without them the menu
    # loops until the user picks Exit or presses Esc.
    $singleShot = $UndeployId -or $UndeployAll -or $Description
    $mode = $null
    if ($UndeployId -or $UndeployAll) {
        $mode = 'Undeploy'
    } elseif ($Description) {
        $mode = 'Deploy'
    }

    while ($true) {
        if (-not $mode) {
            $mode = Show-MainMenu
            if (-not $mode) {
                Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
                exit 2
            }
            if ($mode -eq 'Exit') {
                Write-Host 'Bye.' -ForegroundColor Cyan
                exit 0
            }
        }

        switch ($mode) {
            'Update' {
                $items = @(Get-DeploymentsJson -Path $BackendPath | ForEach-Object {
                    [pscustomobject]@{
                        Id          = [string] $_.DeploymentId
                        Version     = if ($null -eq $_.VersionNumber) { '' } else { [string] $_.VersionNumber }
                        Description = if ($null -eq $_.Description) { '' } else { [string] $_.Description }
                        Url         = "https://script.google.com/macros/s/$([string] $_.DeploymentId)/exec"
                    }
                })
                if ($items.Count -eq 0) {
                    $items = Get-Deployments -Path $BackendPath
                }
                if (-not $items -or $items.Count -eq 0) {
                    Write-Host "No deployments available for $BackendPath." -ForegroundColor Yellow
                    exit 1
                }
    
                # Show newest deployments first in the picker. Use a compatibility
                # path that avoids per-key hashtable sort metadata, which can throw
                # "Argument types do not match" in some host/runtime combinations.
                $items = @(
                    $items |
                    ForEach-Object {
                        $verText = [string] $_.Version
                        $verNum = if ($verText -match '^\d+$') { [int] $verText } else { -1 }
                        [pscustomobject]@{
                            SortVersion = $verNum
                            SortId      = [string] $_.Id
                            Item        = $_
                        }
                    } |
                    Sort-Object -Property SortVersion, SortId -Descending |
                    ForEach-Object { $_.Item }
                )
    
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
            'Undeploy' {
                if ($UndeployAll) {
                    Write-Host ("Undeploying all deployments from {0}..." -f $BackendPath) -ForegroundColor Cyan
                    Invoke-Undeploy -Path $BackendPath -All
                    Write-Host ''
                    Write-Host 'Undeployed all deployments' -ForegroundColor Green
                    Clear-ReleaseInfo -File $ReleaseInfoFile
                }
                elseif ($UndeployId) {
                    Write-Host ("Undeploying {0} from {1}..." -f $UndeployId, $BackendPath) -ForegroundColor Cyan
                    Invoke-Undeploy -Path $BackendPath -DeploymentId $UndeployId
                    Write-Host ''
                    Write-Host ("Undeployed {0}" -f $UndeployId) -ForegroundColor Green
                    Clear-ReleaseInfo -File $ReleaseInfoFile -DeploymentId $UndeployId
                }
                else {
                    # Interactive: pick single vs all first.
                    $subChoice = Show-ListPicker -Options @(
                        [pscustomobject]@{ Key = 'Single'; Label = 'Undeploy a single deployment (pick from list)' }
                        [pscustomobject]@{ Key = 'All';    Label = 'Undeploy ALL deployments' }
                    ) -Title 'Undeploy: single or all?'

                    if (-not $subChoice) {
                        Write-Host 'Cancelled. No changes made.' -ForegroundColor Yellow
                    }
                    elseif ($subChoice.Key -eq 'All') {
                        Write-Host ''
                        Write-Host "This will undeploy EVERY deployment in $BackendPath." -ForegroundColor Yellow
                        Write-Host 'If the frontend API_URL in Index.html still points to one of them,' -ForegroundColor Yellow
                        Write-Host 'update it via option 1 (Update) before going further.' -ForegroundColor Yellow
                        Write-Host ''
                        $confirm = Read-Host "Type 'yes' to undeploy ALL deployments"
                        if ($confirm -ne 'yes') {
                            Write-Host 'Cancelled. No changes made.' -ForegroundColor Yellow
                        } else {
                            Invoke-Undeploy -Path $BackendPath -All
                            Write-Host ''
                            Write-Host 'Undeployed all deployments' -ForegroundColor Green
                            Clear-ReleaseInfo -File $ReleaseInfoFile
                        }
                    }
                    else {
                        $items = @(Get-DeploymentsJson -Path $BackendPath | ForEach-Object {
                            [pscustomobject]@{
                                Id          = [string] $_.DeploymentId
                                Version     = if ($null -eq $_.VersionNumber) { '' } else { [string] $_.VersionNumber }
                                Description = if ($null -eq $_.Description) { '' } else { [string] $_.Description }
                                Url         = "https://script.google.com/macros/s/$([string] $_.DeploymentId)/exec"
                            }
                        })
                        if ($items.Count -eq 0) {
                            $items = Get-Deployments -Path $BackendPath
                        }
                        if (-not $items -or $items.Count -eq 0) {
                            Write-Host "No deployments available for $BackendPath." -ForegroundColor Yellow
                            exit 1
                        }

                        $items = @(
                            $items |
                            ForEach-Object {
                                $verText = [string] $_.Version
                                $verNum = if ($verText -match '^\d+$') { [int] $verText } else { -1 }
                                [pscustomobject]@{
                                    SortVersion = $verNum
                                    SortId      = [string] $_.Id
                                    Item        = $_
                                }
                            } |
                            Sort-Object -Property SortVersion, SortId -Descending |
                            ForEach-Object { $_.Item }
                        )

                        if ($items.Count -eq 1) {
                            $choice = $items[0]
                            Write-Host ("Only one deployment found, will undeploy {0} ({1})." -f $choice.Version, $choice.Id) -ForegroundColor Yellow
                        } else {
                            $choice = Show-Picker -Items $items -Title "Select deployment to undeploy ($BackendPath)"
                            if (-not $choice) {
                                Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
                                exit 2
                            }
                        }

                        Write-Host ''
                        Write-Host "About to undeploy:" -ForegroundColor Yellow
                        Write-Host ("  Id          : {0}" -f $choice.Id) -ForegroundColor Yellow
                        Write-Host ("  Version     : {0}" -f $choice.Version) -ForegroundColor Yellow
                        Write-Host ("  Description : {0}" -f $choice.Description) -ForegroundColor Yellow
                        Write-Host ("  URL         : {0}" -f $choice.Url) -ForegroundColor Yellow
                        Write-Host ''
                        Write-Host "NOTE: If the frontend API_URL in Index.html points to this deployment," -ForegroundColor Red
                        Write-Host "      update it via option 1 (or deploy + Update) to avoid a broken frontend." -ForegroundColor Red
                        Write-Host ''
                        $confirm = Read-Host "Type 'yes' to confirm undeploy"
                        if ($confirm -ne 'yes') {
                            Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
                            exit 2
                        }

                        Invoke-Undeploy -Path $BackendPath -DeploymentId $choice.Id
                        Write-Host ''
                        Write-Host ("Undeployed {0}" -f $choice.Id) -ForegroundColor Green
                        Clear-ReleaseInfo -File $ReleaseInfoFile -DeploymentId $choice.Id
                    }
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

        if ($singleShot) {
            break
        }

        Write-Host ''
        Write-Host 'Press any key to return to the menu (Esc to exit)...' -ForegroundColor DarkGray
        $null = [Console]::ReadKey($true)
        $mode = $null
    }
}
catch {
    $err = $_
    Write-Host ("Error: " + $err.Exception.Message) -ForegroundColor Red
    if ($err.InvocationInfo) {
        Write-Host ("At line {0}: {1}" -f $err.InvocationInfo.ScriptLineNumber, $err.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray
    }
    if ($err.ScriptStackTrace) {
        Write-Host ("Stack: {0}" -f $err.ScriptStackTrace) -ForegroundColor DarkGray
    }
    exit 1
}
