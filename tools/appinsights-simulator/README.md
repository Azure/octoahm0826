# Application Insights multi-tier demo

Standalone PowerShell 7+. No PowerShell modules, SDK packages, deployed services, or real application traffic required. The script constructs synthetic telemetry and posts batches directly to the Application Insights ingestion endpoint.

This tool is separate from the infrastructure lab: it neither instruments that workload nor creates an Azure Monitor health model.

```text
demo-store-web
  -> demo-store-orders
       -> demo-store-inventory -> Redis cache (cache miss)
                              -> SQL database
       -> demo-store-payments  -> external payment provider
```

Four instrumented application roles and their external dependencies are represented. Every checkout has a shared W3C-format trace ID, distinct parent-linked spans, consistent timing, and correlated logs, events, and a checkout-duration metric. Payment failures also produce exception telemetry.

## Send to Application Insights

Use a dedicated demo Application Insights resource: synthetic traffic can trigger alerts, affect dashboards, and incur ingestion charges. Nothing is provisioned or deleted. Open PowerShell 7 in this folder. Replace the placeholder below with the **Connection string** from the resource's Overview page; keep its regional `IngestionEndpoint`.

```powershell
$env:APPLICATIONINSIGHTS_CONNECTION_STRING = '<your demo resource connection string>'
.\Send-DemoTelemetry.ps1
```

The default run lasts roughly four minutes, plus upload time: 60 checkouts per phase, a one-second pause after each checkout, one cycle. Each checkout emits 13 items, plus one exception when it fails. Uploads are synchronous; this is a telemetry simulator, not a load generator.

| Phase | Behavior |
|---|---|
| Healthy | Successful checkouts with short dependency calls. |
| DatabaseSlowdown | Successful SQL calls take 1.8-3.5 seconds; inventory, orders, and web latency increase accordingly. |
| PaymentFailures | About 60% of payment-provider calls return synthetic 503s; failures propagate through payments, orders, and web. Inventory stays healthy. |
| Recovery | Latency returns to baseline and checkouts succeed. |

```powershell
# Repeat the complete cycle.
.\Send-DemoTelemetry.ps1 -Cycles 3

# Hold one scenario, use a distinct application name, and generate traffic faster.
.\Send-DemoTelemetry.ps1 -Scenario DatabaseSlowdown -ApplicationName training-store `
    -RequestsPerPhase 100 -IntervalMilliseconds 200
```

`-Seed` controls repeatable latency/failure choices; trace IDs and timestamps remain unique. All timestamps are current and simulated spans finish before submission. The script does not wait for each invented dependency duration.

### Entra-authenticated ingestion

For a resource with local authentication disabled, sign in with Azure CLI and grant that identity **Monitoring Metrics Publisher** on the target Application Insights resource. The connection string is still required to identify the destination. The script does not change permissions or resource authentication settings.

```powershell
az login
.\Send-DemoTelemetry.ps1 -UseEntraId
```

This option obtains and refreshes Azure CLI tokens for the public Azure Monitor audience (`https://monitor.azure.com/`). Azure CLI is unnecessary for connection-string-only ingestion, which requires the resource to permit local authentication.

## Offline preview

No Azure configuration or network access is needed:

```powershell
.\Send-DemoTelemetry.ps1 -DryRun -RequestsPerPhase 5 -IntervalMilliseconds 0 `
    -OutputPath .\preview.ndjson
```

`-DryRun` never uploads. Without `-OutputPath`, it writes a uniquely named NDJSON file beside the script. Existing files are never overwritten. `-OutputPath` also works during a live run to archive generated envelopes; this archive records generation, not proof of acceptance. Never publish a real connection string or access token.

## Explore the demo

Open the destination resource's **Application map**, **Performance**, **Failures**, and **Transaction search** views. Use a time range covering the run and allow time for ingestion and map discovery. SQL/cache/provider hosts ending in `.invalid` are deliberately fictitious.

All telemetry is labeled with `demo.synthetic=true`, `demo.app`, `demo.runId`, `demo.phase`, `demo.cycle`, and `demo.transaction` in custom properties. The completion summary includes the run ID and acknowledged item count. Standard request/dependency telemetry carries latency and status; `Demo.CheckoutCompleted` and `demo.checkout.duration.ms` provide a business event and custom metric.

Uploads use bounded batches and retry transient HTTP failures. A partial response retries only rejected, retryable items; accepted items are not resent. Permanent rejection stops the run. Network failures with no ingestion response stop rather than blindly replaying a possibly accepted batch. HTTP acceptance is not a guarantee of query visibility or Application Map rendering. Ctrl+C stops the process; unsubmitted in-memory telemetry is not guaranteed to be delivered.

## Local checks

```powershell
.\Test-DemoTelemetry.ps1
```

Checks exercise the actual generator and sender with mocked HTTP and Azure CLI boundaries; they never send to Azure. They cover span correlation/timing, degradation and recovery, file preservation, destination validation, partial acceptance, bounded retries, permanent rejection, Entra token use, and repeated cycles. Live ingestion and portal rendering still require a configured demo resource.

References: [telemetry data model](https://learn.microsoft.com/en-us/azure/azure-monitor/app/data-model-complete), [connection strings](https://learn.microsoft.com/en-us/azure/azure-monitor/app/connection-strings), [Application map](https://learn.microsoft.com/en-us/azure/azure-monitor/app/app-map), [Entra authentication](https://learn.microsoft.com/en-us/azure/azure-monitor/app/azure-ad-authentication).
