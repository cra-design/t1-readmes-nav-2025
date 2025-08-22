<#
.SYNOPSIS
  Integrated builder that preserves links by calling your existing generators,
  then enforces bilingual parity only (no link validation).

.STEPS
  1) Run EN + FR generator scripts (so links are exactly as before).
  2) Parity-only fix: if one language has a link and the other does not,
     set the linked cell to:
        EN: <td><span class="small text-muted">Not available</span></td>
        FR: <td><span class="small text-muted">Pas disponible</span></td>

.PARAMETERS
  -FormsList:    Path to recent-T1-forms-10yrs-bil.txt (one form code per line).
  -ResultsDir:   Output dir for {FORM}-table-e.htm and {FORM}-table-f.htm.
  -EnglishGenerator / -FrenchGenerator: paths to your existing generator scripts.
  -SkipGeneration: if set, do not run generators; only run parity pass.
  -DryRun:       show actions; do not write files.

.NOTES
  This script does NOT validate links across the network. It only fixes the
  case where one language has a link and the other does not.
#>

[CmdletBinding()]
param(
  [string]$FormsList = (Join-Path $PSScriptRoot 'recent-T1-forms-10yrs-bil.txt'),
  [string]$ResultsDir = (Join-Path $PSScriptRoot 'results'),

  [string]$EnglishGenerator = (Join-Path $PSScriptRoot 'generate-t1-readme-tables-10yrs_EN.ps1'),
  [string]$FrenchGenerator  = (Join-Path $PSScriptRoot 'generate-t1-readme-tables-10yrs_FR.ps1'),

  [switch]$SkipGeneration,
  [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Warning $msg }
function Write-Act($msg)  { Write-Host "[DO]   $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "[SKIP] $msg" -ForegroundColor DarkGray }

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    if ($DryRun) { Write-Act ("Would create directory: {0}" -f $Path) }
    else { New-Item -ItemType Directory -Path $Path | Out-Null }
  }
}

function Read-Forms([string]$listPath) {
  if (-not (Test-Path -LiteralPath $listPath)) {
    throw ("Forms list not found: {0}" -f $listPath)
  }
  Get-Content -LiteralPath $listPath |
    Where-Object { $_ -and -not $_.StartsWith('#') } |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' }
}

# --- HTML helpers for parity-only pass ---------------------------------------

function Get-TBodyInner {
  param([string]$Html)
  $rx = [Regex]::new('(?is)<tbody>(.*?)</tbody>')
  $m = $rx.Match($Html)
  if (-not $m.Success) { throw "No <tbody> found." }
  [PSCustomObject]@{
    Pre   = $Html.Substring(0, $m.Groups[1].Index - 7)   # includes <tbody>
    Inner = $m.Groups[1].Value
    Post  = $Html.Substring($m.Groups[1].Index + $m.Groups[1].Length + 8) # after </tbody>
  }
}

function Parse-TableCells {
  param([string]$Html)
  $piece = Get-TBodyInner -Html $Html
  $tbody = $piece.Inner

  $rowRx  = [Regex]::new('(?is)<tr>(.*?)</tr>')
  $cellRx = [Regex]::new('(?is)<td\b.*?>.*?</td>')
  $yearRx = [Regex]::new('(?is)<td\b.*?>(\s*\d{4}\s*)</td>')

  $rows = @()
  foreach ($r in $rowRx.Matches($tbody)) {
    $rowHtml = $r.Groups[1].Value
    $cells = @()
    foreach ($c in $cellRx.Matches($rowHtml)) { $cells += $c.Value }
    if ($cells.Count -lt 1) { continue }
    $ym = $yearRx.Match($rowHtml)
    if (-not $ym.Success) { continue }
    $year = ($ym.Groups[1].Value -replace '\s+','').Trim()
    $rows += [PSCustomObject]@{ Year = $year; Cells = $cells }
  }

  [PSCustomObject]@{
    Pre = $piece.Pre; Inner = $tbody; Post = $piece.Post; Rows = $rows
  }
}

function Replace-CellsInOrder {
  param([string]$HtmlInner,[string[]]$NewCells)
  $rx = New-Object System.Text.RegularExpressions.Regex('<td\b.*?>.*?</td>','Singleline,IgnoreCase')
  $matches = $rx.Matches($HtmlInner)
  if ($matches.Count -ne $NewCells.Count) {
    throw ("Replacement count ({0}) does not match found <td> count ({1})." -f $NewCells.Count, $matches.Count)
  }
  $sb = [System.Text.StringBuilder]::new()
  $last = 0
  for ($i=0; $i -lt $matches.Count; $i++) {
    $m = $matches[$i]
    [void]$sb.Append($HtmlInner.Substring($last, $m.Index - $last))
    [void]$sb.Append($NewCells[$i])
    $last = $m.Index + $m.Length
  }
  [void]$sb.Append($HtmlInner.Substring($last))
  $sb.ToString()
}

function Has-Link([string]$td) {
  # A link exists if there is an <a ... href="..."> with a non-empt
