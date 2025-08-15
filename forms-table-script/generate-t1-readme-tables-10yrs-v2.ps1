param(
    [Parameter(Mandatory=$false)]
    [string]$TemplatePath = (Join-Path -Path $PSScriptRoot -ChildPath "5000-s2-table-e.htm"),

    [Parameter(Mandatory=$false)]
    [string]$FormListPath = (Join-Path -Path $PSScriptRoot -ChildPath "recent-T1-forms-10yrs.txt"),

    [Parameter(Mandatory=$false)]
    [string]$OutputDir = (Join-Path -Path $PSScriptRoot -ChildPath "results"),

    [switch]$Overwrite = $true
)

# --- Config ---
# Token in the template to replace with each form code
$TemplateToken = "5000-s2"

# Replacement HTML for unavailable links
$NotAvailableHtml = '<span class="small text-muted">Not available</span>'

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

# --- Networking setup ---
# Ensure modern TLS
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    # Tls13 may not exist; fall back to Tls12
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Reuse one HttpClient for all requests
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $true
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromSeconds(10)

# Function: return [nullable int] status code, or $null if unknown/error
function Get-StatusCode {
    param(
        [Parameter(Mandatory=$true)][string]$Url
    )
    try {
        # Try HEAD first
        $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $Url)
        $resp = $http.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $resp.Dispose()
        return $code
    } catch {
        # Some servers don't support HEAD; try GET (headers only)
        try {
            $req2 = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
            $resp2 = $http.SendAsync($req2, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $code2 = [int]$resp2.StatusCode
            $resp2.Dispose()
            return $code2
        } catch {
            Write-Warn "Failed to check URL: $Url ($($_.Exception.Message))"
            return $null
        }
    }
}

# Regex for anchor tags with href="..."
$anchorPattern = '<a\b[^>]*?href\s*=\s*"([^"]+)"[^>]*>.*?<\/a>'

# Process each form name
$results = @()
foreach ($form in $formNames) {
    if ($form -notmatch '^[A-Za-z0-9-]+$') {
        Write-Warn "Skipping invalid form name '$form' (only letters, digits, and dashes are allowed)"
        continue
    }

    $outFileName = "$form-table-e.htm"
    $outPath = Join-Path -Path $OutputDir -ChildPath $outFileName

    if ((-not $Overwrite) -and (Test-Path -LiteralPath $outPath)) {
        Write-Warn "Skipping '$form' because output exists: $outPath (use -Overwrite to replace)"
        $results += [pscustomobject]@{
            Form       = $form
            OutputPath = $outPath
            Status     = "Skipped (exists)"
            LinksChecked = 0
            Replaced404  = 0
        }
        continue
    }

    # 1) Replace token to get form-specific HTML
    $content = $template.Replace($TemplateToken, $form)

    # 2) Scan and check links; replace only those that are HTTP 404
    $checked = 0
    $replaced404 = 0

    $evaluator = {
        param($match)
        $url = $match.Groups[1].Value
        $global:checked += 1  # use global vars to mutate within evaluator

        $code = Get-StatusCode -Url $url
        if ($code -eq 404) {
            Write-Warn "[$form] 404 Not Found → $url"
            $global:replaced404 += 1
            return $NotAvailableHtml
        } else {
            if ($code -ne $null) {
                Write-Info "[$form] Link OK ($code) → $url"
            } else {
                Write-Warn "[$form] Could not verify → $url (leaving link as-is)"
            }
            return $match.Value
        }
    }

    # Use globals so the evaluator can increment
    $global:checked = 0
    $global:replaced404 = 0
    $content = [System.Text.RegularExpressions.Regex]::Replace($content, $anchorPattern, $evaluator, 'Singleline, IgnoreCase')
    $checked = $global:checked
    $replaced404 = $global:replaced404

    if ($DryRun) {
        Write-Info "Would write: $outPath"
        $results += [pscustomobject]@{
            Form         = $form
            OutputPath   = $outPath
            Status       = "DryRun"
            LinksChecked = $checked
            Replaced404  = $replaced404
        }
        continue
    }

    # 3) Write output (UTF-8 without BOM)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($outPath, $content, $utf8NoBom)

    Write-Info "Wrote: $outPath"
    $results += [pscustomobject]@{
        Form         = $form
        OutputPath   = $outPath
        Status       = "Created"
        LinksChecked = $checked
        Replaced404  = $replaced404
    }
}

# Cleanup httpclient
$http.Dispose()

# Optional: emit a simple summary table
if ($results.Count -gt 0) {
    $results | Sort-Object Form | Format-Table -AutoSize
}
