#requires -Version 7.0
<#
.SYNOPSIS
Sends synthetic multi-tier online-store telemetry to Application Insights.
.DESCRIPTION
No application services are deployed or contacted. Only the telemetry ingestion
endpoint is contacted. Use -DryRun to generate NDJSON without making network calls.
.EXAMPLE
.\Send-DemoTelemetry.ps1 -DryRun -OutputPath .\preview.ndjson
.EXAMPLE
.\Send-DemoTelemetry.ps1 -UseEntraId -Cycles 2
#>
[CmdletBinding()]
param(
    [string]$ConnectionString = [string]$env:APPLICATIONINSIGHTS_CONNECTION_STRING,
    [switch]$UseEntraId,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,39}$')]
    [string]$ApplicationName = 'demo-store',
    [ValidateSet('Cycle', 'Healthy', 'DatabaseSlowdown', 'PaymentFailures', 'Recovery')]
    [string]$Scenario = 'Cycle',
    [ValidateRange(1, 100000)]
    [int]$RequestsPerPhase = 60,
    [ValidateRange(0, 60000)]
    [int]$IntervalMilliseconds = 1000,
    [ValidateRange(1, 1000)]
    [int]$Cycles = 1,
    [int]$Seed = 42,
    [switch]$DryRun,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$invariant = [Globalization.CultureInfo]::InvariantCulture
$runId = [guid]::NewGuid().ToString('N')
$random = [Random]::new($Seed)
$settings = @{}
foreach ($part in $ConnectionString.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
    $pair = $part.Split('=', 2)
    if ($pair.Count -ne 2) { throw 'Invalid Application Insights connection string.' }
    $settings[$pair[0].Trim()] = $pair[1].Trim()
}
$key = [guid]::Empty
if ($settings.ContainsKey('InstrumentationKey')) {
    if (-not [guid]::TryParse($settings.InstrumentationKey, [ref]$key)) {
        throw 'InstrumentationKey must be a GUID.'
    }
}
if (-not $DryRun -and $key -eq [guid]::Empty) {
    throw 'Set APPLICATIONINSIGHTS_CONNECTION_STRING to the connection string from your demo Application Insights resource.'
}
$endpoint = 'https://dc.services.visualstudio.com/'
if ($settings.ContainsKey('IngestionEndpoint')) {
    $endpoint = $settings.IngestionEndpoint
} elseif ($settings.ContainsKey('EndpointSuffix')) {
    $endpoint = "https://dc.$($settings.EndpointSuffix)/"
}
$ingestionUri = $null
if (-not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$ingestionUri) -or
    $ingestionUri.Scheme -ne 'https' -or $ingestionUri.UserInfo -or
    $ingestionUri.Query -or $ingestionUri.Fragment) {
    throw 'IngestionEndpoint must be an absolute HTTPS base URL without credentials, query, or fragment.'
}
$ingestionUri = [uri]::new($ingestionUri.AbsoluteUri.TrimEnd('/') + '/v2/track')
$applicationId = $settings['ApplicationId']
if ($UseEntraId -and -not $DryRun -and -not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw '-UseEntraId requires Azure CLI. Sign in with az login first.'
}
if ($DryRun -and -not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "demo-$runId.ndjson"
}
$roles = @{
    Web = "$ApplicationName-web"
    Orders = "$ApplicationName-orders"
    Inventory = "$ApplicationName-inventory"
    Payments = "$ApplicationName-payments"
}
$script:accessToken = $null
$script:tokenExpiry = [DateTimeOffset]::MinValue

function New-Envelope {
    param($Type, $Role, [hashtable]$BaseData, $Context, $ParentId, [DateTimeOffset]$Time)
    $BaseData.properties = $Context.Properties
    $tags = @{
        'ai.cloud.role' = $Role
        'ai.cloud.roleInstance' = "$Role-01"
        'ai.application.ver' = '1.0.0-demo'
        'ai.operation.id' = $Context.OperationId
        'ai.operation.name' = 'POST /checkout'
    }
    if ($ParentId) { $tags['ai.operation.parentId'] = $ParentId }
    @{
        name = "Microsoft.ApplicationInsights.$($key.ToString('N')).$Type"
        time = $Time.UtcDateTime.ToString('o', $invariant)
        iKey = $key.ToString()
        sampleRate = 100.0
        tags = $tags
        data = @{ baseType = "${Type}Data"; baseData = $BaseData }
    }
}

function New-CheckoutTelemetry {
    param([string]$Phase, [int]$Cycle, [int]$Sequence)
    $items = [Collections.Generic.List[object]]::new()
    $failed = $Phase -eq 'PaymentFailures' -and $random.Next(100) -lt 60
    $context = @{
        OperationId = [Diagnostics.ActivityTraceId]::CreateRandom().ToHexString()
        Properties = @{
            'demo.synthetic' = 'true'
            'demo.app' = $ApplicationName
            'demo.runId' = $runId
            'demo.phase' = $Phase
            'demo.cycle' = $Cycle.ToString($invariant)
            'demo.transaction' = $Sequence.ToString($invariant)
            'demo.failed' = $failed.ToString().ToLowerInvariant()
        }
    }
    $spans = @{}
    foreach ($name in 'web', 'webOrders', 'orders', 'ordersInventory', 'inventory',
        'cache', 'sql', 'ordersPayments', 'payments', 'provider') {
        $spans[$name] = [Diagnostics.ActivitySpanId]::CreateRandom().ToHexString()
    }
    $cacheMs = $random.Next(3, 11)
    $sqlMs = if ($Phase -eq 'DatabaseSlowdown') { $random.Next(1800, 3501) } else { $random.Next(15, 51) }
    $providerMs = if ($failed) { $random.Next(500, 1001) } else { $random.Next(25, 101) }
    $inventoryMs = $cacheMs + $sqlMs + 15
    $paymentsMs = $providerMs + 12
    $ordersMs = 10 + ($inventoryMs + 10) + 8 + ($paymentsMs + 10) + 10
    $webMs = 15 + ($ordersMs + 10) + 10
    $webStart = [DateTimeOffset]::UtcNow.AddMilliseconds(-$webMs)
    $ordersStart = $webStart.AddMilliseconds(20)
    $inventoryStart = $ordersStart.AddMilliseconds(15)
    $paymentsStart = $ordersStart.AddMilliseconds(10 + $inventoryMs + 10 + 8 + 5)
    $upstreamCode = if ($failed) { '502' } else { '200' }
    $paymentCode = if ($failed) { '503' } else { '200' }

    function Add-Span {
        param($Kind, $Role, $Id, $Parent, [DateTimeOffset]$Start, [int]$Ms, $Name,
            [bool]$Success = $true, $Code = '200', $Target, $DependencyType = 'Http', $Data)
        $base = @{
            ver = 2; id = $Id; name = $Name
            duration = [TimeSpan]::FromMilliseconds($Ms).ToString('c', $invariant)
            success = $Success; resultCode = $Code
        }
        if ($Kind -eq 'Request') {
            $base.responseCode = $Code
            $base.Remove('resultCode')
            $base.url = "https://$Role.demo.invalid$($Name.Split(' ', 2)[1])"
            if ($Parent -and $applicationId) { $base.source = "cid-v1:$applicationId" }
        } else {
            $base.type = $DependencyType
            if ($Target -in $roles.Values) {
                $base.target = "$Target.demo.invalid"
                $base.data = "https://$Target.demo.invalid$($Name.Split(' ', 2)[1])"
                if ($applicationId) { $base.target += " | cid-v1:$applicationId" }
            } else {
                $base.target = $Target
                $base.data = $Data
            }
        }
        $type = if ($Kind -eq 'Request') { 'Request' } else { 'RemoteDependency' }
        $items.Add((New-Envelope $type $Role $base $context $Parent $Start))
    }

    Add-Span Request $roles.Web $spans.web '' $webStart $webMs 'POST /checkout' (-not $failed) $upstreamCode
    Add-Span Dependency $roles.Web $spans.webOrders $spans.web ($webStart.AddMilliseconds(15)) ($ordersMs + 10) 'POST /api/orders' (-not $failed) $upstreamCode $roles.Orders
    Add-Span Request $roles.Orders $spans.orders $spans.webOrders $ordersStart $ordersMs 'POST /api/orders' (-not $failed) $upstreamCode
    Add-Span Dependency $roles.Orders $spans.ordersInventory $spans.orders ($ordersStart.AddMilliseconds(10)) ($inventoryMs + 10) 'GET /api/inventory' $true '200' $roles.Inventory
    Add-Span Request $roles.Inventory $spans.inventory $spans.ordersInventory $inventoryStart $inventoryMs 'GET /api/inventory'
    Add-Span Dependency $roles.Inventory $spans.cache $spans.inventory ($inventoryStart.AddMilliseconds(5)) $cacheMs 'GET inventory:demo-sku' $true '0' "$ApplicationName-cache.demo.invalid:6380" 'Redis' 'GET inventory:demo-sku'
    Add-Span Dependency $roles.Inventory $spans.sql $spans.inventory ($inventoryStart.AddMilliseconds(10 + $cacheMs)) $sqlMs 'Inventory SELECT' $true '0' "$ApplicationName-sql.demo.invalid | store" 'SQL' 'SELECT quantity FROM Inventory WHERE sku = @sku'
    Add-Span Dependency $roles.Orders $spans.ordersPayments $spans.orders ($paymentsStart.AddMilliseconds(-5)) ($paymentsMs + 10) 'POST /api/payments' (-not $failed) $paymentCode $roles.Payments
    Add-Span Request $roles.Payments $spans.payments $spans.ordersPayments $paymentsStart $paymentsMs 'POST /api/payments' (-not $failed) $paymentCode
    Add-Span Dependency $roles.Payments $spans.provider $spans.payments ($paymentsStart.AddMilliseconds(6)) $providerMs 'POST /authorize' (-not $failed) $paymentCode 'payment-provider.demo.invalid' 'Http' 'https://payment-provider.demo.invalid/authorize'

    if ($failed) {
        $exception = @{
            ver = 2; severityLevel = 3
            exceptions = @(@{
                id = 1; outerId = 0
                typeName = 'Demo.PaymentProviderUnavailableException'
                message = 'Synthetic payment provider returned HTTP 503; no real payment was attempted.'
                hasFullStack = $false
            })
        }
        $items.Add((New-Envelope 'Exception' $roles.Payments $exception $context $spans.payments ($paymentsStart.AddMilliseconds(6 + $providerMs))))
    }
    $end = $webStart.AddMilliseconds($webMs)
    $severity = if ($failed) { 3 } elseif ($Phase -eq 'DatabaseSlowdown') { 2 } else { 1 }
    $message = "Synthetic checkout: phase=$Phase, failed=$failed, durationMs=$webMs; inventory cache miss, SQL read, payment authorization."
    $items.Add((New-Envelope 'Message' $roles.Web @{ ver = 2; message = $message; severityLevel = $severity } $context $spans.web $end))
    $items.Add((New-Envelope 'Event' $roles.Web @{ ver = 2; name = 'Demo.CheckoutCompleted'; measurements = @{ durationMs = $webMs } } $context $spans.web $end))
    $metric = @{ ver = 2; metrics = @(@{ name = 'demo.checkout.duration.ms'; kind = 0; value = [double]$webMs }) }
    $items.Add((New-Envelope 'Metric' $roles.Web $metric $context $spans.web $end))
    $items.ToArray()
}

function Send-TelemetryBatch {
    param([object[]]$Items)
    $pending = $Items
    $retryable = @(408, 429, 500, 502, 503, 504)
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $headers = @{}
        if ($UseEntraId) {
            if ($script:tokenExpiry -lt [DateTimeOffset]::UtcNow.AddMinutes(2)) {
                $tokenJson = & az account get-access-token --resource https://monitor.azure.com/ --output json --only-show-errors 2>$null
                if ($LASTEXITCODE -ne 0) { throw 'Azure CLI could not obtain a token. Run az login for the target tenant.' }
                $token = ($tokenJson -join "`n") | ConvertFrom-Json
                $script:accessToken = $token.accessToken
                $script:tokenExpiry = if ($token.PSObject.Properties['expires_on']) {
                    [DateTimeOffset]::FromUnixTimeSeconds([long]$token.expires_on)
                } else {
                    [DateTimeOffset]::UtcNow.AddMinutes(5)
                }
            }
            $headers.Authorization = "Bearer $script:accessToken"
        }
        $body = ConvertTo-Json -InputObject $pending -Depth 15 -Compress
        try {
            $response = Invoke-WebRequest -Uri $ingestionUri -Method Post -Headers $headers `
                -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json; charset=utf-8' `
                -TimeoutSec 30 -SkipHttpErrorCheck -MaximumRedirection 0 -MaximumRetryCount 0
        } catch {
            throw 'No ingestion response received. Delivery may be ambiguous; stopped rather than blindly resending the batch.'
        }
        $status = [int]$response.StatusCode
        if ($status -eq 200) {
            if ($response.Content) {
                $ack = $response.Content | ConvertFrom-Json
                if ($ack.itemsReceived -ne $pending.Count -or $ack.itemsAccepted -ne $pending.Count) {
                    throw 'Ingestion returned HTTP 200 but did not acknowledge the entire batch.'
                }
            }
            return $Items.Count
        }
        if ($status -eq 206) {
            $ack = $response.Content | ConvertFrom-Json
            $errors = @($ack.errors)
            if ($ack.itemsReceived -ne $pending.Count -or
                $ack.itemsAccepted -ne ($pending.Count - $errors.Count) -or $errors.Count -eq 0) {
                throw 'Invalid partial-acceptance response from ingestion.'
            }
            $indices = [Collections.Generic.HashSet[int]]::new()
            $rejected = foreach ($itemError in $errors) {
                $index = [int]$itemError.index
                if ($index -lt 0 -or $index -ge $pending.Count -or -not $indices.Add($index)) {
                    throw 'Invalid rejected-item index in ingestion response.'
                }
                if ([int]$itemError.statusCode -notin $retryable) {
                    throw "Ingestion rejected an item with HTTP $($itemError.statusCode). Run stopped; check schema, authentication, and resource limits."
                }
                $pending[$index]
            }
            # Resending accepted rows would inflate the demo's request counts.
            $pending = @($rejected)
        } elseif ($status -notin $retryable) {
            throw "Ingestion returned HTTP $status. For Entra-only resources, use -UseEntraId and the Monitoring Metrics Publisher role."
        }
        if ($attempt -eq 3) { throw "Ingestion retries exhausted; $($pending.Count) telemetry items remain unaccepted." }
        $delay = [int][Math]::Pow(2, $attempt)
        $retryAfter = 0
        if ([int]::TryParse([string]$response.Headers['Retry-After'], [ref]$retryAfter)) {
            $delay = [Math]::Clamp($retryAfter, 0, 60)
        }
        Start-Sleep -Seconds $delay
    }
}

$writer = $null
$batch = [Collections.Generic.List[object]]::new()
$generated = 0
$accepted = 0
$transactions = 0
$phases = if ($Scenario -eq 'Cycle') { @('Healthy', 'DatabaseSlowdown', 'PaymentFailures', 'Recovery') } else { @($Scenario) }
try {
    if ($OutputPath) {
        $OutputPath = [IO.Path]::GetFullPath($OutputPath)
        $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    }
    $mode = if ($DryRun) { 'OFFLINE' } else { 'LIVE INGESTION' }
    Write-Host "$mode | run=$runId | app=$ApplicationName | cycles=$Cycles"
    if (-not $DryRun) { Write-Warning 'Synthetic data can incur ingestion charges and trigger alerts. Use a dedicated demo resource.' }
    for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
        foreach ($phase in $phases) {
            Write-Host "Cycle $cycle/$Cycles | $phase | $RequestsPerPhase checkouts"
            for ($request = 0; $request -lt $RequestsPerPhase; $request++) {
                $transactions++
                foreach ($item in (New-CheckoutTelemetry $phase $cycle $transactions)) {
                    $generated++
                    if ($writer) { $writer.WriteLine((ConvertTo-Json -InputObject $item -Depth 15 -Compress)) }
                    if (-not $DryRun) { $batch.Add($item) }
                }
                if ($batch.Count -ge 100) {
                    $accepted += Send-TelemetryBatch $batch.ToArray()
                    $batch.Clear()
                }
                if ($IntervalMilliseconds -gt 0) { Start-Sleep -Milliseconds $IntervalMilliseconds }
            }
            if ($batch.Count -gt 0) {
                $accepted += Send-TelemetryBatch $batch.ToArray()
                $batch.Clear()
            }
            if ($writer) { $writer.Flush() }
        }
    }
} finally {
    if ($writer) { $writer.Dispose() }
    $script:accessToken = $null
}
[pscustomobject]@{
    RunId = $runId
    Application = $ApplicationName
    Mode = if ($DryRun) { 'Offline' } else { 'Live' }
    Transactions = $transactions
    GeneratedItems = $generated
    AcceptedItems = $accepted
    OutputPath = $OutputPath
}
