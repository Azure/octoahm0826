#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$simulator = Join-Path $PSScriptRoot 'Send-DemoTelemetry.ps1'
$preview = Join-Path ([IO.Path]::GetTempPath()) "demo-check-$([guid]::NewGuid().ToString('N')).ndjson"
$invariant = [Globalization.CultureInfo]::InvariantCulture
$testState = @{
    Uploads = [Collections.Generic.List[object]]::new()
    ResponseMode = 'accept'
    TokenRequests = 0
    CheckAuthorization = $false
}
$connection = 'InstrumentationKey=11111111-2222-4333-8444-555555555555;IngestionEndpoint=https://example.invalid/;ApplicationId=22222222-3333-4444-8555-666666666666'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $Method, $Headers, [byte[]]$Body, $ContentType, $TimeoutSec,
        [switch]$SkipHttpErrorCheck, $MaximumRedirection, $MaximumRetryCount)
    Assert-True ($Uri.AbsoluteUri -eq 'https://example.invalid/v2/track') 'Wrong ingestion endpoint.'
    Assert-True ($Method -eq 'Post') 'Telemetry must use POST.'
    Assert-True ($ContentType -eq 'application/json; charset=utf-8') 'Wrong upload content type.'
    $text = [Text.Encoding]::UTF8.GetString($Body)
    Assert-True ($text.StartsWith('[')) 'Even one retry item must be serialized as a JSON array.'
    $items = @($text | ConvertFrom-Json)
    if ($testState.CheckAuthorization) {
        Assert-True ($Headers.Authorization -eq 'Bearer synthetic-token-not-valid-in-Azure') 'Missing Entra authorization header.'
    } else {
        Assert-True (-not $Headers.ContainsKey('Authorization')) 'Key-only ingestion must not attach an unexpected token.'
    }
    $testState.Uploads.Add($items)
    $status = 200
    $ack = @{ itemsReceived = $items.Count; itemsAccepted = $items.Count; errors = @() }
    if ($testState.ResponseMode -eq 'partial' -and $testState.Uploads.Count -eq 1) {
        $status = 206
        $ack.itemsAccepted = $items.Count - 1
        $ack.errors = @(@{ index = 2; statusCode = 429; message = 'Synthetic throttling' })
    } elseif ($testState.ResponseMode -eq 'permanent') {
        $status = 206
        $ack.itemsAccepted = $items.Count - 1
        $ack.errors = @(@{ index = 2; statusCode = 400; message = 'Synthetic invalid item' })
    } elseif ($testState.ResponseMode -eq 'network') {
        throw 'Synthetic network failure'
    } elseif ($testState.ResponseMode -eq 'exhaust' -or
        ($testState.ResponseMode -eq 'throttle' -and $testState.Uploads.Count -eq 1)) {
        $status = 429
    }
    @{
        StatusCode = $status
        Content = ConvertTo-Json -InputObject $ack -Depth 5 -Compress
        Headers = @{ 'Retry-After' = '0' }
    }
}

function az {
    Assert-True ($args -contains 'get-access-token') 'Unexpected Azure CLI call.'
    $testState.TokenRequests++
    Set-Variable -Name LASTEXITCODE -Value 0 -Scope 1
    @{
        accessToken = 'synthetic-token-not-valid-in-Azure'
        expires_on = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    } | ConvertTo-Json -Compress
}

try {
    $summary = & $simulator -ConnectionString '' -DryRun -OutputPath $preview `
        -RequestsPerPhase 12 -IntervalMilliseconds 0
    $rows = @(Get-Content -LiteralPath $preview | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($testState.Uploads.Count -eq 0) 'Offline generation must never upload.'
    Assert-True ($summary.Transactions -eq 48 -and $summary.AcceptedItems -eq 0) 'Wrong offline summary.'
    Assert-True ($summary.GeneratedItems -eq $rows.Count) 'Preview must contain every generated envelope.'
    $operations = @($rows | Group-Object -Property { $_.tags.'ai.operation.id' })
    Assert-True ($operations.Count -eq 48) 'Each checkout needs a unique trace.'
    foreach ($operation in $operations) {
        Assert-True ($operation.Name -cmatch '^[0-9a-f]{32}$') 'Trace ID must be W3C-compatible.'
        $spans = @{}
        $roots = @()
        foreach ($row in $operation.Group) {
            Assert-True ($row.data.baseData.properties.'demo.synthetic' -eq 'true') 'Missing synthetic label.'
            if ($row.data.baseType -in @('RequestData', 'RemoteDependencyData')) {
                $id = $row.data.baseData.id
                Assert-True ($id -cmatch '^[0-9a-f]{16}$' -and -not $spans.ContainsKey($id)) 'Invalid or duplicate span ID.'
                $spans[$id] = $row
                if (-not $row.tags.PSObject.Properties['ai.operation.parentId']) { $roots += $row }
            }
        }
        Assert-True ($spans.Count -eq 10 -and $roots.Count -eq 1) 'Expected one connected ten-span transaction.'
        $root = $roots[0]
        foreach ($row in $operation.Group) {
            if (-not $row.tags.PSObject.Properties['ai.operation.parentId']) { continue }
            $parentId = $row.tags.'ai.operation.parentId'
            Assert-True ($spans.ContainsKey($parentId)) 'A span or log has an orphaned parent.'
            $parent = $spans[$parentId]
            $parentStart = [DateTimeOffset]$parent.time
            $parentEnd = $parentStart.Add([TimeSpan]::Parse($parent.data.baseData.duration, $invariant))
            $start = [DateTimeOffset]$row.time
            $end = if ($row.data.baseType -in @('RequestData', 'RemoteDependencyData')) {
                $start.Add([TimeSpan]::Parse($row.data.baseData.duration, $invariant))
            } else { $start }
            Assert-True ($start -ge $parentStart -and $end -le $parentEnd) "Child timing escapes its parent: $($row.data.baseType), $parentId."
        }
        $phase = $root.data.baseData.properties.'demo.phase'
        $sql = @($operation.Group | Where-Object { $_.data.baseType -eq 'RemoteDependencyData' -and $_.data.baseData.type -eq 'SQL' })[0]
        $sqlMs = [TimeSpan]::Parse($sql.data.baseData.duration, $invariant).TotalMilliseconds
        if ($phase -eq 'DatabaseSlowdown') {
            Assert-True ($sqlMs -ge 1800 -and $root.data.baseData.success) 'Slow SQL must increase latency without failing checkout.'
        } else {
            Assert-True ($sqlMs -lt 100) 'Baseline SQL latency must return after degradation.'
        }
        if ($phase -ne 'PaymentFailures') {
            Assert-True ($root.data.baseData.success) 'Healthy, slowdown, and recovery phases must succeed.'
        }
        $payment = @($operation.Group | Where-Object { $_.data.baseType -eq 'RequestData' -and $_.tags.'ai.cloud.role' -eq 'demo-store-payments' })[0]
        Assert-True ($payment.data.baseData.success -eq $root.data.baseData.success) 'Payment failure must propagate to the web request.'
        $exceptions = @($operation.Group | Where-Object { $_.data.baseType -eq 'ExceptionData' })
        Assert-True ($exceptions.Count -eq [int](-not $root.data.baseData.success)) 'Only failed checkouts should have a payment exception.'
        $inventory = @($operation.Group | Where-Object { $_.data.baseType -eq 'RequestData' -and $_.tags.'ai.cloud.role' -eq 'demo-store-inventory' })[0]
        Assert-True $inventory.data.baseData.success 'Payment faults must not fail the inventory tier.'
    }
    $failedRoots = @($rows | Where-Object { $_.data.baseType -eq 'RequestData' -and $_.tags.'ai.cloud.role' -eq 'demo-store-web' -and -not $_.data.baseData.success })
    Assert-True ($failedRoots.Count -gt 0) 'The seeded payment scenario must demonstrate failures.'
    Write-Host 'PASS: offline graph, correlation, timing, faults, recovery, and exceptions'

    $previewHash = (Get-FileHash -LiteralPath $preview).Hash
    $caught = $null
    try {
        & $simulator -ConnectionString '' -DryRun -OutputPath $preview `
            -RequestsPerPhase 1 -IntervalMilliseconds 0 | Out-Null
    } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and (Get-FileHash -LiteralPath $preview).Hash -eq $previewHash) 'Existing previews must not be overwritten.'
    foreach ($invalidConnection in @('', $connection.Replace('https://', 'http://'))) {
        $caught = $null
        try { & $simulator -ConnectionString $invalidConnection | Out-Null } catch { $caught = $_ }
        Assert-True ($null -ne $caught -and $testState.Uploads.Count -eq 0) 'Invalid destination must fail before any upload.'
    }
    Write-Host 'PASS: existing-file preservation and destination validation'

    $common = @{ ConnectionString = $connection; RequestsPerPhase = 1; IntervalMilliseconds = 0; Scenario = 'Healthy' }
    $testState.Uploads.Clear()
    $live = & $simulator @common
    Assert-True ($live.AcceptedItems -eq $live.GeneratedItems -and $testState.Uploads.Count -eq 1) 'Accepted-item accounting is wrong.'
    Assert-True ($testState.Uploads[0].Count -eq 13) 'One healthy checkout must produce thirteen items.'
    Write-Host 'PASS: live upload serialization and acknowledgement accounting'

    $testState.Uploads.Clear()
    $testState.ResponseMode = 'partial'
    $live = & $simulator @common
    Assert-True ($testState.Uploads.Count -eq 2 -and $testState.Uploads[1].Count -eq 1) 'Only the rejected item should be retried.'
    $original = $testState.Uploads[0][2]
    $retried = $testState.Uploads[1][0]
    Assert-True ($original.data.baseData.id -eq $retried.data.baseData.id) 'Partial retry changed the rejected span.'
    Assert-True ($live.AcceptedItems -eq 13) 'Partial acceptance must not inflate or undercount accepted items.'
    Write-Host 'PASS: partial acceptance and one-item JSON-array retry'

    $testState.Uploads.Clear()
    $testState.ResponseMode = 'throttle'
    $live = & $simulator @common
    Assert-True ($testState.Uploads.Count -eq 2 -and $live.AcceptedItems -eq 13) 'Retryable batch rejection must retry without inflating acceptance.'
    Write-Host 'PASS: transient HTTP retry'

    foreach ($mode in 'permanent', 'network') {
        $testState.Uploads.Clear()
        $testState.ResponseMode = $mode
        $caught = $null
        try { & $simulator @common | Out-Null } catch { $caught = $_ }
        Assert-True ($null -ne $caught -and $testState.Uploads.Count -eq 1) "$mode failure must stop without a blind retry."
    }
    Write-Host 'PASS: permanent rejection and ambiguous network failure stop the run'

    $testState.Uploads.Clear()
    $testState.ResponseMode = 'exhaust'
    $caught = $null
    try { & $simulator @common | Out-Null } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $testState.Uploads.Count -eq 4) 'Transient failures must stop after the bounded retry budget.'
    Write-Host 'PASS: retry exhaustion'

    $testState.Uploads.Clear()
    $testState.ResponseMode = 'accept'
    $testState.CheckAuthorization = $true
    $authRun = $common.Clone()
    $authRun.UseEntraId = $true
    $authRun.RequestsPerPhase = 9
    $authRun.Cycles = 2
    $authRun.ApplicationName = 'training-store'
    $live = & $simulator @authRun
    Assert-True ($live.Transactions -eq 18 -and $live.AcceptedItems -eq 234) 'Repeated authenticated cycles have wrong totals.'
    Assert-True ($testState.TokenRequests -eq 1 -and $testState.Uploads.Count -eq 4) 'Token must be reused across bounded uploads.'
    Assert-True ($testState.Uploads[0].Count -le 113) 'The upload buffer must remain bounded.'
    foreach ($upload in $testState.Uploads) {
        foreach ($row in $upload) {
            Assert-True ($row.tags.'ai.cloud.role'.StartsWith('training-store-')) 'Custom application prefix was not applied.'
        }
    }
    Write-Host 'PASS: Entra token use, repeated cycles, custom roles, and bounded batching'
} finally {
    if (Test-Path -LiteralPath $preview) { Remove-Item -LiteralPath $preview -Force }
}
