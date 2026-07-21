param(
  [string]$BaseUrl = "http://127.0.0.1:8000",
  [string]$UserId = "user123",
  [string]$GatewaySecret = "super_secret_gateway_key"
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
        $bodyText = $reader.ReadToEnd()
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

$headers = @{
  "Content-Type"       = "application/json"
  "X-Gateway-Secret"   = $GatewaySecret
  "X-Verified-User-Id" = $UserId
  "X-Auth-Issuer"      = "local-gateway"
}

$badHeaders = @{
  "Content-Type"       = "application/json"
  "X-Gateway-Secret"   = "wrong_secret"
  "X-Verified-User-Id" = $UserId
}

Write-Section "0) Health / Ready"
Invoke-TestRequest -Name "healthz" -Method "GET" -Uri "$BaseUrl/healthz" | Out-Null
Invoke-TestRequest -Name "readyz"  -Method "GET" -Uri "$BaseUrl/readyz"  | Out-Null

Write-Section "1) Valid ingest (should succeed)"
$validIngest = @{
  device_id       = "ringA"
  mode            = "batch"
  start_ts        = "2026-07-21T13:00:00"
  end_ts          = "2026-07-21T13:00:30"
  seq_no          = 100
  sample_rate_hz  = 25.0
  hr              = @(70,71,72)
  spo2            = @(98,97,98)
  ppg             = @(0.20,0.30,0.25)
  accel_x         = @(0.0,0.1,0.0)
  accel_y         = @(0.0,0.0,0.1)
  accel_z         = @(1.0,0.9,1.1)
  schema_version  = 1
  idempotency_key = "idem-100"
}
Invoke-TestRequest -Name "valid_ingest" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $headers -BodyObj $validIngest | Out-Null

Write-Section "2) Duplicate idempotency (should return duplicate=true)"
Invoke-TestRequest -Name "duplicate_ingest" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $headers -BodyObj $validIngest | Out-Null

Write-Section "3) Non-monotonic seq_no (should fail with 409 if enabled)"
$nonMono = @{
  device_id       = "ringA"
  mode            = "batch"
  start_ts        = "2026-07-21T13:01:00"
  end_ts          = "2026-07-21T13:01:30"
  seq_no          = 99   # lower than previous 100
  sample_rate_hz  = 25.0
  hr              = @(69,70,71)
  spo2            = @(97,97,98)
  ppg             = @(0.21,0.22,0.20)
  schema_version  = 1
  idempotency_key = "idem-99"
}
Invoke-TestRequest -Name "non_monotonic_seq" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $headers -BodyObj $nonMono | Out-Null

Write-Section "4) Trigger + immediate trigger (cooldown should block second)"
$triggerBody = @{
  trigger_type = "manual"
  stream_duration_sec = 180
}
Invoke-TestRequest -Name "trigger_first"  -Method "POST" -Uri "$BaseUrl/v1/events/trigger" -Headers $headers -BodyObj $triggerBody | Out-Null
Invoke-TestRequest -Name "trigger_second_immediate" -Method "POST" -Uri "$BaseUrl/v1/events/trigger" -Headers $headers -BodyObj $triggerBody | Out-Null

Write-Section "5) Bad payload validation (invalid HR range -> 400)"
$badPayload = @{
  device_id       = "ringA"
  mode            = "batch"
  start_ts        = "2026-07-21T13:02:00"
  end_ts          = "2026-07-21T13:02:30"
  seq_no          = 101
  sample_rate_hz  = 25.0
  hr              = @(10, 11, 12)  # invalid by validator (20..240)
  spo2            = @(98,98,98)
  ppg             = @(0.2,0.2,0.2)
  schema_version  = 1
  idempotency_key = "idem-101"
}
Invoke-TestRequest -Name "invalid_payload_range" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $headers -BodyObj $badPayload | Out-Null

Write-Section "6) Unauthorized test (wrong gateway secret -> 401)"
Invoke-TestRequest -Name "unauthorized" -Method "POST" -Uri "$BaseUrl/v1/ingest/batch" -Headers $badHeaders -BodyObj $validIngest | Out-Null

Write-Section "7) Final status"
Invoke-TestRequest -Name "status" -Method "GET" -Uri "$BaseUrl/v1/status" -Headers $headers | Out-Null

Write-Host "`nDone." -ForegroundColor Green