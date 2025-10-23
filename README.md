# ZyzyvaTelemetry

**Version 1.0.0** - Shared observability library for the Botify ecosystem.

This library provides a unified wrapper around industry-standard observability tools (Prometheus, Tower, Loki) with ecosystem-specific defaults and conventions.

## Features

- **Metrics Collection** - Via PromEx integration with Prometheus
- **Error Tracking** - Via Tower with structured JSON logging for Loki
- **Health Checks** - Standardized health endpoints for all services
- **Correlation Tracking** - Distributed tracing across services
- **Zero Configuration** - Ecosystem defaults built-in

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:zyzyva_telemetry, github: "zyzyva/zyzyva_telemetry", tag: "v1.0.0"}
  ]
end
```

## Quick Start

### 1. Define Your PromEx Module

```elixir
defmodule MyApp.PromEx do
  use ZyzyvaTelemetry.PromEx,
    otp_app: :my_app,
    service_name: "my_app",
    router: MyAppWeb.Router,
    repos: [MyApp.Repo],
    broadway_pipelines: []  # Add any Broadway pipelines
end
```

### 2. Add to Supervision Tree

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # ... your other children (Repo, PubSub, etc.)

    {ZyzyvaTelemetry.Supervisor,
     service_name: "my_app",
     promex_module: MyApp.PromEx,
     repo: MyApp.Repo}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### 3. Add Routes

```elixir
# lib/my_app_web/router.ex
pipeline :api do
  plug ZyzyvaTelemetry.Plugs.CorrelationTracker
end

# Metrics endpoint (for Prometheus scraping)
scope "/metrics" do
  forward "/", MyApp.PromEx
end

# Health endpoints
get "/health", ZyzyvaTelemetry.HealthController, :check
```

## What Gets Collected

### Automatic Metrics (via PromEx)
- **BEAM VM**: Memory, processes, schedulers, garbage collection
- **Phoenix**: Request duration, counts, errors by route
- **Ecto**: Query duration, pool usage (if repos configured)
- **Broadway**: Pipeline performance (if configured)
- **System**: Via node_exporter on the host

### Error Tracking
- Automatic exception capture via Tower
- Structured JSON logs written to `/var/log/{service_name}/errors.json`
- Includes correlation IDs, stack traces, and metadata
- Ready for Promtail/Loki ingestion

### Health Status
- Memory usage with thresholds
- Process count monitoring
- Database connectivity (if repo provided)
- Custom health checks
- Exposed at `/health` endpoint

## Usage

### Correlation Tracking

Track requests across distributed services:

```elixir
# In a Phoenix plug or controller
ZyzyvaTelemetry.with_correlation(correlation_id, fn ->
  # All logs and errors within this block
  # will include the correlation_id
  perform_operation()
end)

# Or manually manage correlation
ZyzyvaTelemetry.set_correlation_id("request-123")
# ... do work ...
ZyzyvaTelemetry.get_correlation_id()  # Returns "request-123"
```

### Custom Metrics

Emit custom telemetry events that will be collected by Prometheus:

```elixir
# Track deployments
ZyzyvaTelemetry.track_deployment("my_app", :success)

# Track errors
ZyzyvaTelemetry.track_error("my_app", "payment_failed")

# Track business operations with timing
:telemetry.span(
  [:ecosystem, :business, :operation],
  %{service_name: "my_app", operation: "process_order"},
  fn ->
    # Your operation here
    result = process_order()
    {result, %{}}
  end
)
```

### Health Checks

Register custom health checks:

```elixir
# In your application startup
ZyzyvaTelemetry.report_health(:rabbitmq, fn ->
  # Return true if healthy, false otherwise
  check_rabbitmq_connection()
end)

# Get current health status
health = ZyzyvaTelemetry.get_health()
# Returns: %{status: "healthy", service: "my_app", ...}
```

## Integration with Monitoring Stack

This library is designed to work with the Botify ecosystem monitoring stack:

1. **Prometheus** scrapes metrics from `/metrics` endpoint
2. **Promtail** ships JSON error logs from `/var/log/*/errors.json` to Loki
3. **Grafana** provides unified visualization of metrics and logs

See the [monitoring-stack](../monitoring-stack) repository for infrastructure setup.

## Configuration

The library works with minimal configuration, but you can customize:

```elixir
# Optional: Configure PromEx settings
config :my_app, MyApp.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: [
    host: "http://localhost:3000",
    auth_token: "your_token"
  ]

# Optional: Configure health check interval
{ZyzyvaTelemetry.Supervisor,
 service_name: "my_app",
 promex_module: MyApp.PromEx,
 repo: MyApp.Repo,
 check_interval: 60_000}  # Check every 60 seconds instead of default 30
```

## Migration from v0.1.0 (SQLite-based)

If upgrading from the SQLite-based v0.1.0:

1. **Run cleanup script** to remove SQLite artifacts:
   ```bash
   ./cleanup_v1_resources.sh
   ```

2. **Update supervision tree** (see Quick Start above)

3. **Update dependencies**:
   ```elixir
   # Remove
   {:exqlite, "~> 0.33"}

   # Add (handled automatically by zyzyva_telemetry)
   {:prom_ex, "~> 1.11"},
   {:tower, "~> 0.6"},
   {:telemetry_metrics, "~> 1.0"},
   {:telemetry_poller, "~> 1.1"}
   ```

4. **Remove deprecated function calls**:
   - `log_error/1,2` → Use Tower error tracking instead
   - `log_warning/1,2` → Use standard Logger
   - `log_exception/3,4` → Exceptions are captured automatically by Tower
   - `generate_test_events/0` → No longer needed

5. **Update health endpoints**:
   ```elixir
   # Old
   get "/health", ZyzyvaTelemetry.HealthController, []

   # New (same syntax, but different backend)
   get "/health", ZyzyvaTelemetry.HealthController, :check
   ```

## Advanced Usage

### Custom Health Checks

Add sophisticated health checks:

```elixir
{ZyzyvaTelemetry.Supervisor,
 service_name: "my_app",
 promex_module: MyApp.PromEx,
 repo: MyApp.Repo,
 extra_health_checks: %{
   redis: fn -> check_redis_connection() end,
   queue_depth: fn ->
     depth = MyApp.Queue.depth()
     depth < 1000  # healthy if queue depth < 1000
   end
 }}
```

### Custom PromEx Plugins

Create ecosystem-specific metrics:

```elixir
defmodule MyApp.CustomPlugin do
  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      counter("my_app.custom.events",
        event_name: [:my_app, :custom, :event],
        description: "Custom event counter",
        tags: [:type]
      )
    ]
  end
end

# In your PromEx module
defmodule MyApp.PromEx do
  use ZyzyvaTelemetry.PromEx,
    otp_app: :my_app,
    service_name: "my_app",
    router: MyAppWeb.Router,
    repos: [MyApp.Repo],
    additional_plugins: [MyApp.CustomPlugin]
end
```

## Architecture

ZyzyvaTelemetry v1.0 wraps industry-standard tools:

- **PromEx** - Elixir Prometheus client with built-in plugins
- **Tower** - Error tracking and reporting
- **Telemetry** - Standard Elixir metrics and instrumentation
- **Health Registry** - In-memory health check management

The library provides:
- Pre-configured PromEx setup with ecosystem defaults
- Automatic Tower reporter writing JSON logs for Loki
- Correlation ID tracking across distributed services
- Standardized health endpoints

## Requirements

- Elixir ~> 1.18
- Phoenix ~> 1.7 (optional, for web endpoints)
- Ecto ~> 3.10 (optional, for database metrics)
- Broadway ~> 1.0 (optional, for pipeline metrics)

## License

MIT