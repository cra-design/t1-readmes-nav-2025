<# 
Compare bilingual HTML tables and enforce link parity.

- Reads form names from .\recent-T1-forms-10yrs-bil.txt
- For each $formname, processes:
    .\results\$formname-table-e.htm  (English)
    .\results\$formname-table-f.htm  (French)

Rule:
- For each (Year, Column≥1), if exactly one language's cell contains a link (<a ... href="...">) 
  and the other does not, replace the linked cell's inner HTML with:
    EN: <span class="small text-muted">Not available</span>
    FR: <span class="small text-muted">Pas disponible</span>

Edits in place with timestamped backups and a console report of changes.
No external dependencies.

Author: ChatGPT (GPT-5 Thinking)
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------ Helpers ------------
function New-Timestamp {
    Get-Date -Format 'yyyyMMdd-HHmmss'
}

# Extract the first <tbody>...</tbody> block
function Get-TbodyBlock {
    param(
        [Parameter(Mandatory=$true)][string]$Html
    )
    $m = [Regex]::Match($Html, '(?is)<tbody\b[^>]*>(.*?)</tbody>')
    if (-not $m.Success) {
        throw "No <tbody> found."
    }
    return [PSCustomObject]@{
        FullMatch = $m.Value
        Inner     = $m.Groups[1].Value
        Index     = $m.Index
        Length    = $m.Length
    }
}

# Parse rows and cells within a tbody inner HTML.
# Returns rows as list. Each row has:
# - Year : [string] (from first cell)
# - Cells: list of cell objects:
#     - OpenTag : "<td ...>"
#     - Inner   : innerHTML
#     - CloseTag: "</td>"
#     - Href    : extracted href (if any)
#     - HasLink : [bool]
function Parse-Tbody {
    param(
        [Parameter(Mandatory=$true)][string]$TbodyInner,
        [Parameter(Mandatory=$true)][ValidateSet('en','fr')]$Lang
    )

    $rows = New-Object System.Collections.Generic.List[object]
    $rowRegex = [Regex]::new('(?is)<tr\b[^>]*>(.*?)</tr>')
    $cellRegex = [Regex]::new('(?is)<td\b([^>]*)>(.*?)</td>')
    $hrefRegex = [Regex]::new('(?is)<a\b[^>]*?href\s*=\s*"([^"]+)"')

    foreach ($rowMatch in $rowRegex.Matches($TbodyInner)) {
        $rowHtmlInner = $rowMatch.Groups[1].Value
        $cells = New-Object System.Collections.Generic.List[object]

        foreach ($cellMatch in $cellRegex.Matches($rowHtmlInner)) {
            $open = "<td{0}>" -f $cellMatch.Groups[1].Value
            $inner = $cellMatch.Groups[2].Value
            $href = $null
            $hasLink = $false
            $hm = $hrefRegex.Match($inner)
            if ($hm.Success -and $hm.Groups[1].Value.Trim() -ne '') {
                $href = $hm.Groups[1].Value.Trim()
                $hasLink = $true
            }

            $cells.Add([PSCustomObject]@{
                OpenTag = $open
                Inner   = $inner
                CloseTag= '</td>'
                Href    = $href
                HasLink = $hasLink
                Lang    = $Lang
            })
        }

        if ($cells.Count -gt 0) {
            $year = ($cells[0].Inner -replace '(?s)<.*?>','').Trim()
            $rows.Add([PSCustomObject]@{
                Year  = $year
                Cells = $cells
            })
        }
    }

    return $rows
}

# Build a map: Year -> row object (for quick pairing)
function Map-RowsByYear {
    param([Parameter(Mandatory=$true)]$Rows)
    $dict = @{}
    foreach ($r in $Rows) { if ($r.Year) { $dict[$r.Year] = $r } }
    return $dict
}

# Rebuild the tbody HTML from parsed rows (Cells[].OpenTag + Inner + CloseTag)
function Build-TbodyInner {
    param([Parameter(Mandatory=$true)]$Rows)
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $Rows) {
        [void]$sb.AppendLine('      <tr>')
        foreach ($c in $r.Cells) {
            [void]$sb.Append($c.OpenTag)
            [void]$sb.Append($c.Inner)
            [void]$sb.AppendLine($c.CloseTag)
        }
        [void]$sb.AppendLine('      </tr>')
    }
    return $sb.ToString()
}

# Produce language-appropriate "not available" inner HTML (ONLY inner, not including <td> tags)
function Get-NAInnerHtml {
    param([Parameter(Mandatory=$true)][ValidateSet('en','fr')]$Lang)
    if ($Lang -eq 'en') {
        return '<span class="small text-muted">Not available</span>'
    } else {
        return '<span class="small text-muted">Pas disponible</span>'
    }
}

# Overwrite the inner HTML of a specific cell
function Set-Cell-NA {
    param(
        [Parameter(Mandatory=$true)]$Cell,
        [Parameter(Mandatory=$true)][ValidateSet('en','fr')]$Lang
    )
    $Cell.Inner = Get-NAInnerHtml -Lang $Lang
    $Cell.HasLink = $false
    $Cell.Href = $null
}

# Safely save with timestamped backup
function Save-WithBackup {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Content
    )
    if (-not (Test-Path $Path)) {
        throw "File not found: $Path"
    }
    $ts = New-Timestamp
    $backup = "$Path.bak-$ts"
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    return $backup
}

# ------------ Main ------------
$root = Get-Location
$listPath = Join-Path $root 'recent-T1-forms-10yrs-bil.txt'
$resultsDir = Join-Path $root 'results'

if (-not (Test-Path $listPath)) {
    throw "List file not found: $listPath"
}
if (-not (Test-Path $resultsDir)) {
    throw "Results folder not found: $resultsDir"
}

$forms = Get-Content -LiteralPath $listPath | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }

$globalChanges = 0
$globalWarnings = 0
$processed = 0

foreach ($formname in $forms) {
    $enPath = Join-Path $resultsDir ("{0}-table-e.htm" -f $formname)
    $frPath = Join-Path $resultsDir ("{0}-table-f.htm" -f $formname)

    if (-not (Test-Path $enPath)) { Write-Warning "[$formname] Missing EN file: $enPath"; $globalWarnings++; continue }
    if (-not (Test-Path $frPath)) { Write-Warning "[$formname] Missing FR file: $frPath"; $globalWarnings++; continue }

    $enHtml = Get-Content -LiteralPath $enPath -Raw
    $frHtml = Get-Content -LiteralPath $frPath -Raw

    try {
        $enTbody = Get-TbodyBlock -Html $enHtml
        $frTbody = Get-TbodyBlock -Html $frHtml

        $enRows = Parse-Tbody -TbodyInner $enTbody.Inner -Lang en
        $frRows = Parse-Tbody -TbodyInner $frTbody.Inner -Lang fr

        $enMap = Map-RowsByYear -Rows $enRows
        $frMap = Map-RowsByYear -Rows $frRows

        $changesThisPair = 0

        # For each year present in BOTH
        foreach ($year in $enMap.Keys) {
            if (-not $frMap.ContainsKey($year)) { 
                Write-Warning "[$formname][$year] Present in EN, missing in FR. Skipping year."
                $globalWarnings++
                continue
            }

            $rowEN = $enMap[$year]
            $rowFR = $frMap[$year]

            # Column 0 is Year; compare 1..N using min of both row cell counts
            $maxCols = [Math]::Min($rowEN.Cells.Count, $rowFR.Cells.Count)
            for ($i = 1; $i -lt $maxCols; $i++) {
                $cellEN = $rowEN.Cells[$i]
                $cellFR = $rowFR.Cells[$i]

                $enHas = $cellEN.HasLink
                $frHas = $cellFR.HasLink

                if ($enHas -xor $frHas) {
                    if ($enHas) {
                        $old = $cellEN.Href
                        Set-Cell-NA -Cell $cellEN -Lang en
                        $changesThisPair++
                        $globalChanges++
                        Write-Output ("CHANGED  {0}  Year={1}  Col={2}  lang=en  removedHref=""{3}""" -f $formname, $year, $i, $old)
                    } else {
                        $old = $cellFR.Href
                        Set-Cell-NA -Cell $cellFR -Lang fr
                        $changesThisPair++
                        $globalChanges++
                        Write-Output ("CHANGED  {0}  Year={1}  Col={2}  lang=fr  removedHref=""{3}""" -f $formname, $year, $i, $old)
                    }
                }
                # else: both link or both NA — no change
            }
        }

        if ($changesThisPair -gt 0) {
            # Rebuild tbodies and reinsert into full HTML
            $newEnTbodyInner = Build-TbodyInner -Rows $enRows
            $newFrTbodyInner = Build-TbodyInner -Rows $frRows

            $newEnHtml = $enHtml.Remove($enTbody.Index, $enTbody.Length).Insert($enTbody.Index, "<tbody>`r`n$newEnTbodyInner    </tbody>")
            $newFrHtml = $frHtml.Remove($frTbody.Index, $frTbody.Length).Insert($frTbody.Index, "<tbody>`r`n$newFrTbodyInner    </tbody>")

            $enBackup = Save-WithBackup -Path $enPath -Content $newEnHtml
            $frBackup = Save-WithBackup -Path $frPath -Content $newFrHtml

            Write-Output ("SAVED    {0}  changes={1}  backups: EN={2}  FR={3}" -f $formname, $changesThisPair, (Split-Path $enBackup -Leaf), (Split-Path $frBackup -Leaf))
        } else {
            Write-Output ("NO-CHANGE {0}" -f $formname)
        }

        $processed++
    }
    catch {
        Write-Warning "[$formname] Error: $($_.Exception.Message)"
        $globalWarnings++
        continue
    }
}

Write-Host ""
Write-Host "Done."
Write-Host ("Processed pairs: {0}" -f $processed)
Write-Host ("Cells changed:   {0}" -f $globalChanges)
Write-Host ("Warnings:        {0}" -f $globalWarnings)
