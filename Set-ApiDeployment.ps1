#requires -Version 7
<#
.SYNOPSIS
    Lists Google Apps Script deployments of the backend project and rewrites
    the API_URL constant in frontend/Index.html with the user-selected one.

.DESCRIPTION
    Runs `clasp deployments` from the backend folder, parses each line into
    DeploymentId / Version / Description and shows an interactive arrow-key
    picker (Up/Down to move, Enter to select, Esc to cancel, Home/End to
    jump). After confirmation it updates:

        const API_URL = 'https://script.google.com/macros/s/<ID>/exec';

    inside frontend/Index.html, preserving the rest of the file.

.PARAMETER BackendPath
    Path to the clasp project folder (must contain .clasp.json).
    Defaults to "../backend" relative to this script.

.PARAMETER FrontendFile
    Path to the HTML file holding the API_URL constant.
    Defaults to "../frontend/Index.html" relative to this script.

.PARAMETER WhatIf
    If set, performs a dry-run: lists deployments, lets you pick, and
    prints the resulting URL but never modifies any file.

.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1
.EXAMPLE
    pwsh ./tools/Set-ApiDeployment.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $BackendPath = (Join-Path $PSScriptRoot '..' 'backend'),
    [string] $FrontendFile = (Join-Path $PSScriptRoot '..' 'frontend' 'Index.html')
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

try {
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
}
catch {
    Write-Host ("Error: " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
