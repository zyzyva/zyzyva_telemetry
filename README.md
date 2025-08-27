# ZyzyvaTelemetry

A lightweight monitoring library for distributed Elixir applications that provides local-first error logging, health reporting, and distributed tracing without network blocking.

## Features

- **Local-first monitoring** - Writes to shared SQLite database at `/var/lib/monitoring/events.db`
- **Zero network blocking** - All writes are local file operations
- **Automatic health reporting** - Configurable periodic health checks
- **Correlation ID tracking** - Follow requests across multiple services
- **Minimal dependencies** - Only requires `exqlite`, uses native JSON module

## Installation

Add `zyzyva_telemetry` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zyzyva_telemetry, "~> 0.1.0"}
  ]
end
```

### Database Setup

The monitoring database needs to be created at `/var/lib/monitoring/events.db`. This typically requires elevated permissions.

#### From Development

```bash
# Using the included setup module
mix run -e "ZyzyvaTelemetry.Setup.init()"
```

#### From a Release

```bash
# The setup module is available in your release
./my_app eval "ZyzyvaTelemetry.Setup.init()"

# Or with a custom path
./my_app eval "ZyzyvaTelemetry.Setup.init('/custom/path/events.db')"
```

#### Manual Setup

If you prefer to set up the directory manually:

```bash
sudo mkdir -p /var/lib/monitoring
sudo chown $USER:$USER /var/lib/monitoring
sudo chmod 755 /var/lib/monitoring
```

The database file and tables will be created automatically when the application starts.

## Usage

### Quick Setup for Phoenix Apps

Run the setup task to generate integration code:

```bash
mix zyzyva.setup
```

This will:
- Generate a test helper for health endpoint testing
- Add test configuration for a temporary test database
- Show detailed integration instructions with proper pipeline setup

Follow the printed instructions to:
1. Add the MonitoringSupervisor to your supervision tree
2. Add correlation tracking to your browser pipeline
3. Add the health endpoint with proper pipeline routing
4. Create health endpoint tests

### Integration

Add ZyzyvaTelemetry as a supervised child in your application:

```elixir
def start(_type, _args) do
  children = [
    # ... your existing children
    {ZyzyvaTelemetry.MonitoringSupervisor,
     service_name: "my_app",
     repo: MyApp.Repo,  # Optional: for database health checks
     broadway_pipelines: [MyApp.Pipeline.Broadway]}  # Optional: for RabbitMQ monitoring
  ]
  
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Logging Errors

```elixir
# Simple error
ZyzyvaTelemetry.log_error("Something went wrong")

# Error with metadata
ZyzyvaTelemetry.log_error("Failed to process", %{user_id: 123, action: "create"})

# Warning
ZyzyvaTelemetry.log_warning("Memory usage high")

# Exception with stack trace
try do
  risky_operation()
rescue
  e ->
    ZyzyvaTelemetry.log_exception(e, __STACKTRACE__, "Operation failed")
end
```

### Correlation Tracking

For Phoenix applications, add the correlation plug to your pipeline:

```elixir
pipeline :browser do
  # ... other plugs
  plug ZyzyvaTelemetry.Plugs.CorrelationTracker
end

# Add health endpoint with correlation tracking
scope "/" do
  pipe_through :browser  # Important: use pipeline for correlation
  get "/health", ZyzyvaTelemetry.HealthController, :index
end
```

Track requests programmatically:

```elixir
# Set correlation ID for distributed tracing
ZyzyvaTelemetry.with_correlation(request_id, fn ->
  # All errors logged here will include the correlation ID
  process_request()
end)

# Or manually manage correlation
ZyzyvaTelemetry.set_correlation("request-123")
ZyzyvaTelemetry.log_error("Failed") # Will include correlation ID
```

### Broadway/RabbitMQ Monitoring

The `AppMonitoring` module can automatically monitor Broadway pipelines:

```elixir
ZyzyvaTelemetry.AppMonitoring.init(
  repo: MyApp.Repo,
  broadway_pipelines: [
    MyApp.Pipeline.Broadway,
    MyApp.AnotherPipeline.Broadway
  ]
)
```

This will include RabbitMQ connection status in health checks.

### Health Reporting

The health reporter runs automatically at configured intervals. You can also report manually:

```elixir
# Manual health report
ZyzyvaTelemetry.report_health(%{
  status: :degraded,
  reason: "High memory usage",
  memory_mb: 1024
})

# Custom health check function
def health_check do
  %{
    status: :healthy,
    queue_depth: MyApp.Queue.depth(),
    connections: MyApp.ConnectionPool.active_count()
  }
end
```

## Testing

A test helper template is provided in `test_helper_template.ex.example`. Copy this file to your app's `test/support/` directory and update the module name to match your app's namespace. This provides reusable assertions for testing health endpoints.

Example usage:
```elixir
defmodule MyAppWeb.HealthControllerTest do
  use MyAppWeb.ConnCase
  import MyAppWeb.HealthEndpointTestHelper

  test "GET /health returns telemetry data", %{conn: conn} do
    conn = get(conn, "/health")
    body = assert_health_endpoint(conn,
      service_name: "my_app",
      required_fields: ["memory", "processes", "database_connected"]
    )
  end
end
```

## Architecture

ZyzyvaTelemetry writes all monitoring data to a local SQLite database that is shared by all applications on the server. A separate aggregator service (not included) can forward this data to a central monitoring system.

The SQLite database path `/var/lib/monitoring/events.db` is designed to be shared across all services on a single server, enabling efficient local aggregation before forwarding to central monitoring.

