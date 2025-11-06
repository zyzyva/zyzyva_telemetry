# Loki Integration - Direct HTTP Push

## Overview

ZyzyvaTelemetry v2 now supports **direct HTTP push to Loki**, eliminating the need to install Promtail on every application server.

## Why Direct HTTP Push?

**Benefits:**
- ✅ No Promtail installation required on application servers
- ✅ No Docker setup needed on application servers
- ✅ Real-time log delivery to Loki
- ✅ Simpler architecture - one less service to maintain
- ✅ Automatic buffering via async Task
- ✅ Works with any Loki instance accessible via HTTP

**Trade-offs:**
- ⚠️ Logs sent asynchronously (won't block app if Loki is down)
- ⚠️ If app crashes before sending, some logs might be lost (rare)
- ℹ️ For high-volume logging, file + Promtail might be better

## Configuration

### Option 1: Pass Loki URL Directly (Recommended)

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # ... other children ...

    {ZyzyvaTelemetry.Supervisor,
     service_name: "my_app",
     promex_module: MyApp.PromEx,
     repo: MyApp.Repo,
     loki_url: "http://192.168.1.101:3100"}  # Your Loki LAN IP (fast!)
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Option 2: Use Environment Variable

```bash
# Set LOKI_URL environment variable
# Use LAN IP for fast server-to-server communication
export LOKI_URL="http://192.168.1.101:3100"
```

```elixir
# lib/my_app/application.ex
# ZyzyvaTelemetry will automatically use LOKI_URL env var
{ZyzyvaTelemetry.Supervisor,
 service_name: "my_app",
 promex_module: MyApp.PromEx,
 repo: MyApp.Repo}
```

### Option 3: Use File Logging (Legacy - Requires Promtail)

If you prefer file-based logging with Promtail:

```elixir
{ZyzyvaTelemetry.Supervisor,
 service_name: "my_app",
 promex_module: MyApp.PromEx,
 repo: MyApp.Repo,
 use_file_logging: true}  # Will write to /var/log/my_app/errors.json
```

## How It Works

1. **Application catches an exception** via Tower
2. **Tower calls the Loki reporter** with the error details
3. **Reporter builds Loki-formatted payload**:
   ```json
   {
     "streams": [
       {
         "stream": {
           "job": "errors",
           "service": "my_app",
           "level": "ERROR",
           "kind": "exit"
         },
         "values": [
           ["1234567890000000000", "{\"timestamp\":\"2025-10-21T...\",\"message\":\"...\",\"stacktrace\":\"...\"}"]
         ]
       }
     ]
   }
   ```
4. **HTTP POST to Loki** at `http://loki:3100/loki/api/v1/push`
5. **Loki stores the log** - immediately searchable in Grafana

## Loki Configuration

No changes needed to your Loki configuration! The HTTP API is enabled by default.

Your existing Loki setup from `monitoring-stack` works as-is.

## Viewing Logs in Grafana

1. Open Grafana: `http://100.104.83.12:3000`
2. Go to **Explore**
3. Select **Loki** datasource
4. Query examples:
   ```logql
   # All errors from a specific service
   {service="my_app"}

   # Errors with specific kind
   {service="my_app", kind="exit"}

   # Search for specific text in message
   {service="my_app"} |= "database"

   # Errors with a specific correlation ID
   {service="my_app"} | json | correlation_id="abc-123-def"
   ```

## Testing

To test error reporting, trigger an exception in your application:

```elixir
# In iex or a controller
raise "Test error for Loki"
```

Then check Grafana Loki explorer for the log entry.

## Migration from File Logging

If you're currently using file-based logging with Promtail:

1. **Update ZyzyvaTelemetry** dependency to v2.1+
2. **Add `loki_url` to your supervisor config**
3. **Deploy the application**
4. **Verify logs appear in Grafana**
5. **Stop Promtail service** (optional - can keep running for other logs)

No downtime required - both methods can run simultaneously during migration.

## Troubleshooting

### Logs not appearing in Grafana?

1. Check app logs for Loki connection errors:
   ```
   [error] Failed to push to Loki: HTTP 500
   ```

2. Verify Loki URL is correct and accessible from app server:
   ```bash
   curl http://100.104.83.12:3100/ready
   ```

3. Check Loki logs for ingestion errors:
   ```bash
   docker logs loki
   ```

### High error volume causing issues?

Switch to file-based logging with Promtail for better buffering:

```elixir
{ZyzyvaTelemetry.Supervisor,
 service_name: "my_app",
 promex_module: MyApp.PromEx,
 use_file_logging: true}
```

## Performance

- **HTTP push overhead**: ~1-5ms per error (async, non-blocking)
- **Memory usage**: Minimal (1 Task per error)
- **Network bandwidth**: ~1-5KB per error (JSON payload)

For normal error volumes (< 100 errors/sec), HTTP push is perfectly fine.

## Security

- Uses standard HTTP POST (no authentication by default)
- Loki should be on private network (Tailscale) or behind firewall
- No sensitive data is logged automatically
- Correlation IDs included for tracing

## Next Steps

- Configure alerts in Grafana for high error rates
- Create dashboards showing error trends
- Set up email notifications for critical errors
