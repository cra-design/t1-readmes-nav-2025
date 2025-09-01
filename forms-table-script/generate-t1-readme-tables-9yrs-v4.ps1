<#
To run this ".\generate-t1-readme-tables-9yrs-v4.ps1 -EnableConsoleHttpDebug"

.SYNOPSIS
  Validates CRA T1 tables PER TABLE (English and French separately).
  If a cell's link is invalid (HTTP 4xx/5xx or request error), that cell is replaced:
    EN: <span class="small text-muted">Not available</span>
    FR: <span class="small text-muted">Pas disponible</span>

.DESCRIPTION
  - Reads a manifest list (one slug per line, e.g., 5005-s1).
  - For each slug, opens:
        results\<slug>-table-e.htm   (English)
        results\<slug>-table-f.htm   (French)
  - Parses <tbody> rows (Year + 4 columns: Fillable, Standard, Large print, E-text).
  - For each cell, validates its <a href>. If invalid, replaces ONLY that cell for that table.
  - Writes back preserving original encoding (accents like “Année”, “électronique” remain correct).

  Windows PowerShell 5.1 safe:
   - Single reusable HttpClient, TLS 1.2
   - HEAD first then retry GET on ANY non-2xx/3xx
   - No PS7-only operators

#>

[CmdletBinding()]
param(
  # Root of your project (defaults to the script folder)
  [string]$Root = $( if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } ),

  # Manifest listing slugs (e.g., 5005-s1) one per line
  [string]$Manifest = $( Join-Path $( if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } ) 'recent-T1-forms-9yrs.txt' ),

  # Show per-URL statuses while running
  [switch]$EnableConsoleHttpDebug
)

# ---------------------------
# HTTP bootstrap for WinPS 5.1
# ---------------------------
try {
  [void][System.Net.ServicePointManager]::SecurityProtocol
  $global:__origTls = [System.Net.ServicePointManager]::SecurityProtocol
  [System.Net.ServicePointManager]::SecurityProtocol = $global:__origTls -bor [System.Net.SecurityProtocolType]::Tls12
} catch { }

$script:HttpClient = $null
function New-HttpClient {
  if ($script:HttpClient -ne $null) { return $script:HttpClient }
  $handler = New-Object System.Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $true
  $handler.MaxAutomaticRedirections = 10

  $client = New-Object System.Net.Http.HttpClient($handler)
  $client.Timeout = [TimeSpan]::FromSeconds(30)
  $client.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/5.1")
  $client.DefaultRequestHeaders.ExpectContinue = $false
  $client.DefaultRequestHeaders.Accept.ParseAdd("*/*")

  $script:HttpClient = $client
  return $client
}

# Small in-memory cache to avoid rechecking the same URL
$script:UrlStatusCache = @{}

# Returns @{ IsGood; Code; Method; Error; FinalUri }
function Test-UrlStatus {
  param([Parameter(Mandatory=$true)][string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return [PSCustomObject]@{ IsGood=$false; Code=$null; Method='HEAD'; Error='(empty URL)'; FinalUri=$null }
  }
  if ($script:UrlStatusCache.ContainsKey($Url)) { return $script:UrlStatusCache[$Url] }

  $client = New-HttpClient
  $u = $Url.Trim()

  function _mkres([bool]$ok,[Nullable[Int32]]$code,[string]$method,[string]$err,[Uri]$finalUri) {
    [PSCustomObject]@{ IsGood=$ok; Code=$code; Method=$method; Error=$err; FinalUri=$finalUri }
  }

  try {
    # HEAD first
    $req1  = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Head, $u)
    $res1  = $client.SendAsync($req1,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $code1 = [int]$res1.StatusCode
    $fin1  = $res1.RequestMessage.RequestUri
    $ok1   = ($code1 -ge 200 -and $code1 -lt 400)
    if ($EnableConsoleHttpDebug) { Write-Host ("[HEAD] {0} -> {1}" -f $u, $code1) }
    $res1.Dispose(); $req1.Dispose()

    if ($ok1) {
      $result = _mkres $true $code1 "HEAD" $null $fin1
      $script:UrlStatusCache[$Url] = $result
      return $result
    }

    # Retry with GET for any non-OK HEAD
    $req2  = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $u)
    $res2  = $client.SendAsync($req2,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    $code2 = [int]$res2.StatusCode
    $fin2  = $res2.RequestMessage.RequestUri
    $ok2   = ($code2 -ge 200 -and $code2 -lt 400)
    if ($EnableConsoleHttpDebug) { Write-Host ("[ GET] {0} -> {1}" -f $u, $code2) }
    $res2.Dispose(); $req2.Dispose()

    $result = _mkres $ok2 $code2 "GET" $null $fin2
    $script:UrlStatusCache[$Url] = $result
    return $result
  } catch {
    $msg = $_.Exception.Message
    if ($EnableConsoleHttpDebug) { Write-Host ("[ERR ] {0} -> {1}" -f $u, $msg) }
    $result = _mkres $false $null "GET" $msg $null
    $script:UrlStatusCache[$Url] = $result
    return $result
  }
}

# ---------------------------
# Encoding-safe file I/O (preserve accents)
# ---------------------------
function Read-FileWithEncoding {
  param([Parameter(Mandatory=$true)][string]$Path)
  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
  try {
    $sr = New-Object System.IO.StreamReader($fs, $true)  # detect BOMs, default UTF-8
    $text = $sr.ReadToEnd()
    $enc  = $sr.CurrentEncoding
    $sr.Close()
  } finally {
    $fs.Dispose()
  }
  [PSCustomObject]@{ Text = $text; Encoding = $enc }
}

function Write-FileWithEncoding {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text,
    [Parameter(Mandatory=$true)][System.Text.Encoding]$Encoding
  )
  $enc = if ($Encoding) { $Encoding } else { [System.Text.Encoding]::UTF8 }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# ---------------------------
# HTML parsing / rewriting
# ---------------------------
# Parse a CRA table like:
#   Year | Fillable | Standard | Large print | E-text
# (See 5005-s1 English/French examples)
function Parse-CraTableRows {
  param([string]$Html)

  $rows = @()
  $tbodyMatch = [regex]::Match($Html, '<tbody>(?<body>[\s\S]*?)</tbody>', 'IgnoreCase')
  if (-not $tbodyMatch.Success) { return $rows }

  $tbody = $tbodyMatch.Groups['body'].Value
  $trRegex = New-Object System.Text.RegularExpressions.Regex '<tr>(?<row>[\s\S]*?)</tr>', 'IgnoreCase'
  $tdRegex = New-Object System.Text.RegularExpressions.Regex '<td>(?<cell>[\s\S]*?)</td>', 'IgnoreCase'
  $hrefRegex = New-Object System.Text.RegularExpressions.Regex 'href\s*=\s*"(.*?)"', 'IgnoreCase'

  foreach ($trm in $trRegex.Matches($tbody)) {
    $rowHtml = $trm.Groups['row'].Value
    $tds = @()
    foreach ($tdm in $tdRegex.Matches($rowHtml)) {
      $tds += $tdm.Groups['cell'].Value
    }
    if ($tds.Count -lt 5) { continue } # need Year + 4 cells

    $year = $tds[0]
    $cells = @($tds[1], $tds[2], $tds[3], $tds[4])

    $hrefs = @()
    foreach ($c in $cells) {
      $hm = $hrefRegex.Match($c)
      if ($hm.Success) { $hrefs += $hm.Groups[1].Value } else { $hrefs += $null }
    }

    $rows += [PSCustomObject]@{
      Year  = $year
      Cells = $cells
      Hrefs = $hrefs
    }
  }
  return $rows
}

function Build-CraTbodyHtml {
  param([object[]]$Rows)
  $sb = New-Object System.Text.StringBuilder
  foreach ($r in $Rows) {
    [void]$sb.AppendLine('      <tr>')
    [void]$sb.AppendLine("        <td>$($r.Year)</td>")
    for ($i=0; $i -lt 4; $i++) {
      [void]$sb.AppendLine("        <td>$($r.Cells[$i])</td>")
    }
    [void]$sb.AppendLine('      </tr>')
  }
  return $sb.ToString()
}

function Replace-Tbody {
  param([string]$Html,[string]$NewTbodyInner)
  return [regex]::Replace($Html, '<tbody>[\s\S]*?</tbody>', "<tbody>`r`n$NewTbodyInner    </tbody>", 'IgnoreCase')
}

# Language-specific placeholder
function Get-PlaceholderHtml {
  param([ValidateSet('en','fr')][string]$Lang)
  if ($Lang -eq 'fr') { return '<span class="small text-muted">Pas disponible</span>' }
  return '<span class="small text-muted">Not available</span>'
}

# Validate one table (language-specific: 'en' or 'fr')
function Patch-One-Table {
  param(
    [Parameter(Mandatory=$true)][ValidateSet('en','fr')]$Lang,
    [Parameter(Mandatory=$true)][string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) { Write-Host "Skip (missing): $Path"; return }

  $f = Read-FileWithEncoding -Path $Path
  $html = $f.Text
  $rows = Parse-CraTableRows -Html $html

  $changedRows = @()
  for ($r=0; $r -lt $rows.Count; $r++) {
    $row = $rows[$r]
    $cells = @($row.Cells[0], $row.Cells[1], $row.Cells[2], $row.Cells[3])

    for ($c=0; $c -lt 4; $c++) {
      $url = $row.Hrefs[$c]
      if ([string]::IsNullOrWhiteSpace($url)) {
        # No link present => already "Not available"; leave as is
        continue
      }

      $res = Test-UrlStatus -Url $url
      if (-not $res.IsGood) {
        $cells[$c] = Get-PlaceholderHtml -Lang $Lang
        if ($EnableConsoleHttpDebug) {
          $code = if ($res.Code) { $res.Code } else { $null }
          Write-Host ("[{0} BAD] Row={1} Col={2} Code={3} {4}" -f $Lang.ToUpper(), ($r+1), ($c+1), $code, $url)
        }
      } elseif ($EnableConsoleHttpDebug) {
        Write-Host ("[{0} OK ] Row={1} Col={2} Code={3} {4}" -f $Lang.ToUpper(), ($r+1), ($c+1), $res.Code, $url)
      }
    }

    $changedRows += [PSCustomObject]@{
      Year  = $row.Year
      Cells = $cells
      Hrefs = $row.Hrefs
    }
  }

  $newTbody = Build-CraTbodyHtml -Rows $changedRows
  $outHtml  = Replace-Tbody -Html $html -NewTbodyInner $newTbody
  Write-FileWithEncoding -Path $Path -Text $outHtml -Encoding $f.Encoding

  Write-Host ("Patched ({0}): {1}" -f $Lang.ToUpper(), [IO.Path]::GetFileName($Path))
}

# ---------------------------
# Driver
# ---------------------------
if (-not (Test-Path -LiteralPath $Manifest)) {
  throw "Manifest not found: $Manifest"
}
$slugs = Get-Content -LiteralPath $Manifest | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }

foreach ($slug in $slugs) {
  $enPath = Join-Path $Root ("results\{0}-table-e.htm" -f $slug)
  $frPath = Join-Path $Root ("results\{0}-table-f.htm" -f $slug)

  # Validate EN and FR tables independently
  Patch-One-Table -Lang 'en' -Path $enPath
  Patch-One-Table -Lang 'fr' -Path $frPath
}

Write-Host "Done."
