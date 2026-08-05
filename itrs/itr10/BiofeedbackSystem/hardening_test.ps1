param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [string]$BearerToken = ""
)

$ErrorActionPreference = "Stop"

function Write-Section($title) {
  Write-Host ""
  Write-Host "==================================================" -ForegroundColor Cyan
  Write-Host $title -ForegroundColor Cyan
  Write-Host "==================================================" -ForegroundColor Cyan
}

function Invoke-TestRequest {
  param(
    [string]$Name,
    [string]$Method,
    [string]$Uri,
    [hashtable]$Headers = $null,
    [object]$BodyObj = $null
  )

  Write-Host "`n[$Name] $Method $Uri" -ForegroundColor Yellow
  try {
    $irmParams = @{
      Method = $Method
      Uri    = $Uri
    }

    if ($Headers) { $irmParams.Headers = $Headers }

    if ($BodyObj -ne $null) {
      $irmParams.Body = ($BodyObj | ConvertTo-Json -Depth 10)
      if (-not $Headers.ContainsKey("Content-Type")) {
        $Headers["Content-Type"] = "application/json"
      }
      $irmParams.Headers = $Headers
    }

    $resp = Invoke-RestMethod @irmParams
    Write-Host "Status: SUCCESS (2xx)" -ForegroundColor Green
    $resp | Format-List
    return @{ Ok = $true; Response = $resp }
  }
  catch {
    $ex = $_.Exception
    $statusCode = $null
    $bodyText = $null

    if ($ex.Response -and $ex.Response.StatusCode) {
      $statusCode = [int]$ex.Response.StatusCode
      try {
        if ($ex.Response -and $ex.Response.GetResponseStream()) {
            $stream = $ex.Response.GetResponseStream()
            if ($stream.CanRead) {
                $reader = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
            }
        }
      } catch {}
    }

    Write-Host "Status: ERROR" -ForegroundColor Red
    if ($statusCode) { Write-Host "HTTP Status: $statusCode" -ForegroundColor Red }
    if ($bodyText)   { Write-Host "Body: $bodyText" -ForegroundColor DarkRed }

    return @{
      Ok = $false
      StatusCode = $statusCode
      Body = $bodyText
      Error = $_
    }
  }
}

if ([string]::IsNullOrWhiteSpace($BearerToken)) {
  throw "Provide -BearerToken with a Google ID token"
}

$headers = @{
  "Content-Type"  = "application/json"
  "Authorization" = "Bearer $BearerToken"
}

Write-Section "0) Health / Ready"
Invoke-TestRequest -Name "healthz" -Method "GET" -Uri "$BaseUrl/healthz" | Out-Null
Invoke-TestRequest -Name "readyz"  -Method "GET" -Uri "$BaseUrl/readyz"  | Out-Null

Write-Section "1) Valid ingest (points-only schema)"
$validIngest = @{
  device_id       = "ringA"
  mode            = "batch"
  seq_no          = 100
  schema_version  = 1
  idempotency_key = "idem-100"
  points = @(
    @{ ts = "2026-07-21T13:00:00Z"; hr = 70.0; hrv = 31.2; br = 12.1 },
    @{ ts = "2026-07-21T13:00:05Z"; hr = 71.0; hrv = 30.9; br = 12.4 },
    @{ ts = "2026-07-21T13:00:10Z"; hr = 72.0; hrv = 32.1; br = 12.0 }
  )
}
Invoke-TestRequest -Name "valid_ingest" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $headers -BodyObj $validIngest | Out-Null

Write-Section "2) Status"
Invoke-TestRequest -Name "status" -Method "GET" -Uri "$BaseUrl/v1/status" -Headers $headers | Out-Null

Write-Host "`nDone." -ForegroundColor Green