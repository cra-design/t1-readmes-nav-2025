<# 
Validate-T1-BilingualLinks.ps1

Checks bilingual (EN/FR) tables for each $formname in recent-T1-forms-10yrs.txt.
For each matching EN/FR cell (excluding the first “Year/Année” column):
- If BOTH links return HTTP 200 => leave as-is
- Otherwise => replace the cell HTML with:
   EN: <td><span class="small text-muted">Not available</span></td>
   FR: <td><span class="small text-muted">Pas disponible</span></td>

Assumptions:
- Files live under .\results\ as $formname-table-e.htm(l) and $formname-table-f.htm(l)
- Tables share the same row/column layout and are in a single <tbody> block

Usage:
  pwsh .\Validate-T1-BilingualLinks.ps1
  # Optional flags:
  #   -FormsPath 'recent-T1-forms-10yrs.txt' -ResultsFolder '.\results' -TimeoutSec 12 -DryRun

#>

[CmdletBinding()]
param(
  [string]$FormsPath = ".\recent-T1-forms-10yrs.txt",
  [string]$ResultsFolder = ".\results",
  [int]$TimeoutSec = 12,
  [switch]$DryRun
)

# ---- Helpers ---------------------------------------------------------------

function Resolve-TablePath {
  param(
    [Parameter(Mandatory)] [string]$ResultsFolder,
    [Parameter(Mandatory)] [string]$FormName,
    [Parameter(Mandatory)] [ValidateSet('e','f')] [string]$Lang
  )
  $candidates = @(
    Join-Path $ResultsFolder "$FormName-table-$Lang.htm",
    Join-Path $ResultsFolder "$FormName-table-$Lang.html"
  )
  foreach ($p in $candidates) { if (Test-Path -LiteralPath $p) { return $p } }
  return $candidates[0] # default (even if missing)
}

function Get-TBodyHtml {
  param([string]$Html)
  $m = [regex]::Match($Html, '<tbody>(?<tb>.*?)</tbody>', 'Singleline,IgnoreCase')
  if (-not $m.Success) { return $null }
  return $m.Groups['tb'].Value
}

function Set-TBodyHtml {
  param([string]$Html, [string]$NewTbody)
  return [regex]::Replace(
    $Html,
    '<tbody>.*?</tbody>',
    "<tbody>$NewTbody</tbody>",
    'Singleline,IgnoreCase'
  )
}

function Split-Rows {
  param([string]$TbodyHtml)
  $rows = [regex]::Matches($TbodyHtml, '<tr>(?<row>.*?)</tr>', 'Singleline,IgnoreCase')
  return @($rows | ForEach-Object { $_.Groups['row'].Value })
}

function Split-Cells {
  param([string]$RowHtml)
  $cells = [regex]::Matches($RowHtml, '<td>(?<cell>.*?)</td>', 'Singleline,IgnoreCase')
  return @($cells | ForEach-Object { $_.Groups['cell'].Value })
}

function Join-Cells {
  param([string[]]$Cells)
  return ($Cells | ForEach-Object { "<td>$($_)</td>" }) -join ''
}

function Join-Rows {
  param([string[]]$Rows) # Rows should already contain inner <td> … </td> markup
  return ($Rows | ForEach-Object { "<tr>$($_)</tr>" }) -join "`r`n"
}

function Get-LinkHref {
  param([string]$CellHtml)
  $m = [regex]::Match($CellHtml, 'href\s*=\s*"([^"]+)"', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Is-NotAvailableCell {
  param([string]$CellHtml)
  # Matches either EN or FR Not Available cells as specified
  return [regex]::IsMatch(
    $CellHtml,
    '<span\s+class\s*=\s*"small\s+text-muted"\s*>\s*(Not\s+available|Pas\s+disponible)\s*</span>',
    'IgnoreCase'
  )
}

function Test-Url200 {
  param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 10)

  try {
    # Try HEAD first for speed
    $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { return $true }
  } catch {
    try {
      # Fallback to GET (some servers dislike HEAD)
      $resp2 = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
      if ($resp2.StatusCode -eq 200) { return $true }
    } catch {
      return $false
    }
  }
  return $false
}

$EN_NA = '<span class="small text-muted">Not available</span>'
$FR_NA = '<span class="small text-muted">Pas disponible</span>'

# ---- Main ------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $FormsPath)) {
  throw "Forms list not found: $FormsPath"
}
if (-not (Test-Path -LiteralPath $ResultsFolder)) {
  throw "Results folder not found: $ResultsFolder"
}

$forms = Get-Content -LiteralPath $FormsPath | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($form in $forms) {
  $enPath = Resolve-TablePath -ResultsFolder $ResultsFolder -FormName $form -Lang 'e'
  $frPath = Resolve-TablePath -ResultsFolder $ResultsFolder -FormName $form -Lang 'f'

  if (-not (Test-Path -LiteralPath $enPath)) {
    Write-Warning "EN file missing for $form ($enPath). Skipping."
    continue
  }
  if (-not (Test-Path -LiteralPath $frPath)) {
    Write-Warning "FR file missing for $form ($frPath). Skipping."
    continue
  }

  $enHtml = Get-Content -LiteralPath $enPath -Raw
  $frHtml = Get-Content -LiteralPath $frPath -Raw

  $enTbody = Get-TBodyHtml $enHtml
  $frTbody = Get-TBodyHtml $frHtml
  if ($null -eq $enTbody -or $null -eq $frTbody) {
    Write-Warning "Could not locate <tbody> in one or both files for $form. Skipping."
    continue
  }

  $enRows = Split-Rows $enTbody
  $frRows = Split-Rows $frTbody

  if ($enRows.Count -ne $frRows.Count) {
    Write-Warning "Row count mismatch for $form (EN=$($enRows.Count), FR=$($frRows.Count)). Using min rows."
  }
  $rowCount = [Math]::Min($enRows.Count, $frRows.Count)

  $changed = 0
  for ($ri = 0; $ri -lt $rowCount; $ri++) {
    $enCells = Split-Cells $enRows[$ri]
    $frCells = Split-Cells $frRows[$ri]
    if ($enCells.Count -eq 0 -or $frCells.Count -eq 0) { continue }

    $colCount = [Math]::Min($enCells.Count, $frCells.Count)

    # Column 0 is Year/Année => start at 1
    for ($ci = 1; $ci -lt $colCount; $ci++) {
      $enCell = $enCells[$ci]
      $frCell = $frCells[$ci]

      # If either side already shows "Not available", force both to NA (keeps bilingual symmetry)
      $enIsNA = Is-NotAvailableCell $enCell
      $frIsNA = Is-NotAvailableCell $frCell
      if ($enIsNA -or $frIsNA) {
        if ($enCell -notmatch $EN_NA) { $enCells[$ci] = $EN_NA }
        if ($frCell -notmatch $FR_NA) { $frCells[$ci] = $FR_NA }
        $changed++
        continue
      }

      $enHref = Get-LinkHref $enCell
      $frHref = Get-LinkHref $frCell

      $enValid = $false
      $frValid = $false

      if ($enHref) { $enValid = Test-Url200 -Url $enHref -TimeoutSec $TimeoutSec }
      if ($frHref) { $frValid = Test-Url200 -Url $frHref -TimeoutSec $TimeoutSec }

      if (-not ($enValid -and $frValid)) {
        $enCells[$ci] = $EN_NA
        $frCells[$ci] = $FR_NA
        $changed++
      }
    }

    $enRows[$ri] = (Join-Cells $enCells)
    $frRows[$ri] = (Join-Cells $frCells)
  }

  $newEnTbody = Join-Rows $enRows
  $newFrTbody = Join-Rows $frRows
  $outEnHtml = Set-TBodyHtml -Html $enHtml -NewTbody $newEnTbody
  $outFrHtml = Set-TBodyHtml -Html $frHtml -NewTbody $newFrTbody

  if ($DryRun) {
    Write-Host "[DRY RUN] $form => would modify $changed cell(s)."
  } else {
    Set-Content -LiteralPath $enPath -Value $outEnHtml -Encoding UTF8
    Set-Content -LiteralPath $frPath -Value $outFrHtml -Encoding UTF8
    Write-Host "$form => modified $changed cell(s)."
  }

  $summary.Add([pscustomobject]@{
    Form     = $form
    EN_File  = $enPath
    FR_File  = $frPath
    Changed  = $changed
  })
}

Write-Host "`nSummary:"
$summary | Format-Table -AutoSize
