param(
    [Parameter(Mandatory=$false)]
    [string]$TemplatePath = ".\5000-s2-table-10yrs.htm",

    [Parameter(Mandatory=$false)]
    [string]$FormListPath = ".\recent-T1-forms-10yrs.txt",

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = ".\results",

    [switch]$Overwrite,

    [switch]$DryRun
)

# --- Config ---
# The placeholder token inside the template that will be replaced
# Everywhere the token appears (file names, links, visible text) will be swapped.
# Example token is present in the provided template: 5000-s2
# If you ever change templates, update this to the token used inside the content.
$TemplateToken = "5000-s2"

# --- Helpers ---
function Write-Info($msg){ Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg){ Write-Warning $msg }
function Write-Err($msg){ Write-Host "[ERROR] $msg" -ForegroundColor Red }

# --- Validate inputs ---
if (-not (Test-Path -LiteralPath $TemplatePath)) {
    Write-Err "Template file not found: $TemplatePath"
    exit 1
}

if (-not (Test-Path -LiteralPath $FormListPath)) {
    Write-Err "Form list file not found: $FormListPath"
    exit 1
}

# Ensure output directory exists
if (-not (Test-Path -LiteralPath $OutputDir)) {
    if ($DryRun) {
        Write-Info "Would create output directory: $OutputDir"
    } else {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
        Write-Info "Created output directory: $OutputDir"
    }
}

# Load template content (as raw string, preserving newlines)
$template = Get-Content -LiteralPath $TemplatePath -Raw

# Sanity-check: does the template contain the token we plan to replace?
if ($template -notmatch [Regex]::Escape($TemplateToken)) {
    Write-Warn "The template does not contain the token '$TemplateToken'. No replacements will occur."
}

# Read list of form names (one per line). Ignore blanks and lines starting with '#'
$formNames = Get-Content -LiteralPath $FormListPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") }

if (-not $formNames -or $formNames.Count -eq 0) {
    Write-Err "No form names found in $FormListPath"
    exit 1
}

Write-Info "Loaded $($formNames.Count) form name(s) from $FormListPath"

# Process each form name
$results = @()
foreach ($form in $formNames) {
    # Form code validation: allow letters, digits, and dashes (eg. 5000-s2)
    if ($form -notmatch '^[A-Za-z0-9-]+$') {
        Write-Warn "Skipping invalid form name '$form' (only letters, digits, and dashes are allowed)"
        continue
    }

    $outFileName = "$form-table-10yrs.htm"
    $outPath = Join-Path -Path $OutputDir -ChildPath $outFileName

    if ((-not $Overwrite) -and (Test-Path -LiteralPath $outPath)) {
        Write-Warn "Skipping '$form' because output exists: $outPath (use -Overwrite to replace)"
        $results += [pscustomobject]@{
            Form       = $form
            OutputPath = $outPath
            Status     = "Skipped (exists)"
        }
        continue
    }

    # Literal replace of the token everywhere it appears
    $content = $template.Replace($TemplateToken, $form)

    if ($DryRun) {
        Write-Info "Would write: $outPath"
        $results += [pscustomobject]@{
            Form       = $form
            OutputPath = $outPath
            Status     = "DryRun"
        }
        continue
    }

    # Write the file (UTF8 w/o BOM for web)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outPath, $content, $utf8NoBom)

    Write-Info "Wrote: $outPath"
    $results += [pscustomobject]@{
        Form       = $form
        OutputPath = $outPath
        Status     = "Created"
    }
}

# Optional: emit a simple summary table
if ($results.Count -gt 0) {
    $results | Sort-Object Form | Format-Table -AutoSize
}
