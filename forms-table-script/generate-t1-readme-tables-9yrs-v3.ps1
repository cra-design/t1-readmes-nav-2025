<# 
Generate CRA form tables (EN/FR) from templates.
- Input files (same folder as script unless you pass full paths):
    - recent-T1-forms-9yrs.txt  (one form code per line, e.g. 5000-s2, 5002-c, 5014-tc)
    - 5000-s2-table-e.htm       (English template)
    - 5000-s2-table-f.htm       (French template)
- Output:
    - results\<FORM>-table-e.htm
    - results\<FORM>-table-f.htm

French rule for <=2019:
- Directory segment stays /<EN_FORM>/ (e.g., /5000-s2/)
- File names switch to 51xx… using (+100) on the first four digits 
  (e.g., 5000-s2 → 5100-s2, 5002-c → 5102-c), preserving the suffix (-s2, -tc, etc.)
#>

[CmdletBinding()]
param(
  [string]$FormsListPath = ".\recent-T1-forms-9yrs.txt",
  [string]$TemplateEnPath = ".\5000-s2-table-e.htm",
  [string]$TemplateFrPath = ".\5000-s2-table-f.htm",
  [string]$OutputDir       # optional, override if you want
)

# If user didn't pass -OutputDir, always create/use 'results' folder beside this script
if (-not $PSBoundParameters.ContainsKey('OutputDir') -or [string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot 'results'
}

# Make sure it exists
[System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

Write-Host "OutputDir => $OutputDir" -ForegroundColor Cyan

function Ensure-FileExists {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Required file not found: $Path"
  }
}

try {
  Ensure-FileExists -Path $FormsListPath
  Ensure-FileExists -Path $TemplateEnPath
  Ensure-FileExists -Path $TemplateFrPath

  $forms = Get-Content -LiteralPath $FormsListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") }

  if (-not $forms) {
    throw "No form codes found in $FormsListPath"
  }

  $templateEn = Get-Content -LiteralPath $TemplateEnPath -Raw
  $templateFr = Get-Content -LiteralPath $TemplateFrPath -Raw

  if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
  }

  $total = 0
  foreach ($form in $forms) {
    # $form looks like: 5000-s2, 5002-c, 5014-tc, etc.
    if ($form -notmatch '^\d{4}-.+$') {
      Write-Warning "Skipping invalid form code: '$form'"
      continue
    }

    $first4 = [int]$form.Substring(0,4)
    $suffix = $form.Substring(4)  # includes hyphen, e.g. "-s2", "-tc"
    $frPre2019 = ($first4 + 100).ToString() + $suffix  # e.g. 5002-c -> 5102-c

    # EN page: replace all occurrences of the example code in the template (5000-s2) with the target form
    $enOut = $templateEn -replace [regex]::Escape('5000-s2'), [System.Text.RegularExpressions.Regex]::Escape($form).Replace('\','\\')

    # FR page requires two passes:
    #  1) Replace all '5000-s2' (directory segments and >=2020 filenames) with the target EN form (e.g., 5002-c)
    #  2) Replace all '5100-s2' (the <=2019 filenames in the template) with computed FR legacy code (e.g., 5102-c)
    $frOut = $templateFr -replace [regex]::Escape('5000-s2'), [System.Text.RegularExpressions.Regex]::Escape($form).Replace('\','\\')
    $frOut = $frOut -replace [regex]::Escape('5100-s2'), [System.Text.RegularExpressions.Regex]::Escape($frPre2019).Replace('\','\\')

    $outEnPath = Join-Path $OutputDir "$form-table-e.htm"
    $outFrPath = Join-Path $OutputDir "$form-table-f.htm"

    # Write as UTF-8 without BOM for consistency
    [System.IO.File]::WriteAllText($outEnPath, $enOut, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($outFrPath, $frOut, [System.Text.UTF8Encoding]::new($false))

    Write-Host "Generated:" -ForegroundColor Green
    Write-Host "  $outEnPath"
    Write-Host "  $outFrPath"
    $total++
  }

  Write-Host ""
  Write-Host "Done. Created $total form pair(s) in '$OutputDir'." -ForegroundColor Cyan

} catch {
  Write-Error $_.Exception.Message
  exit 1
}
