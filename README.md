# ZyzyvaTelemetry

A lightweight monitoring library for distributed Elixir applications that provides local-first error logging, health reporting, and distributed tracing without network blocking.

## Features

- **Local-first monitoring** - Writes to shared SQLite database at `/var/lib/monitoring/events.db`
- **Zero network blocking** - All writes are local file operations
- **Automatic health reporting** - Configurable periodic health checks
- **Correlation ID tracking** - Follow requests across multiple services
- **OTP supervision** - Proper supervision tree integration via MonitoringSupervisor
- **Broadway monitoring** - Built-in RabbitMQ/Broadway pipeline health checks
- **Minimal dependencies** - Only requires `exqlite` and `plug`, uses Elixir 1.18+ native JSON

## Requirements

- Elixir 1.18+ (for native JSON support)
- Write access to `/var/lib/monitoring/` or configured database path

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

Run the setup task for automated integration:

```bash
mix zyzyva.setup
```

This comprehensive setup task will:
- Generate a test helper module for health endpoint testing
- Automatically add test configuration to `config/test.exs`
- Create a temporary test database configuration
- Provide complete integration code snippets for your application
- Show Broadway pipeline configuration examples (if applicable)

The task provides copy-paste ready code for:
1. Adding MonitoringSupervisor to your application supervision tree
2. Configuring Broadway pipelines in your config files
3. Adding correlation tracking to your browser pipeline
4. Setting up the health endpoint with proper routing
5. Creating comprehensive health endpoint tests

### Integration

The MonitoringSupervisor is the primary integration point. Add it to your application's supervision tree:

```elixir
# In lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # ... your existing children (Repo, PubSub, etc.)
    
    # Add the monitoring supervisor
    {ZyzyvaTelemetry.MonitoringSupervisor,
     service_name: "my_app",
     repo: MyApp.Repo,  # Optional: for database health checks
     broadway_pipelines: Application.get_env(:my_app, :broadway_pipelines, [])}
  ]
  
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

#### Configuration-Based Broadway Monitoring

For cleaner separation of concerns, configure Broadway pipelines in your config files:

```elixir
# config/config.exs
config :my_app,
  broadway_pipelines: [
    MyApp.Pipeline.Broadway,
    MyApp.AnotherPipeline.Broadway
  ]

# config/test.exs - Override for test environment
config :my_app,
  broadway_pipelines: []  # No Broadway pipelines in test
```

This approach keeps your application.ex clean and makes it easy to configure different pipelines per environment.

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

Broadway pipeline monitoring is built into the MonitoringSupervisor. When you provide the `broadway_pipelines` option, the health reporter will automatically:

- Check if each Broadway pipeline process is running
- Report `rabbitmq_connected: true/false` in health checks
- Include Broadway status in overall health determination

The monitoring works by checking if the named Broadway processes are alive, which indicates RabbitMQ connectivity.

### Health Reporting

The health reporter runs automatically at configured intervals (default: 30 seconds). Health data includes:

- Memory usage with automatic status thresholds
- Process count monitoring
- Database connectivity (if repo configured)
- Broadway/RabbitMQ status (if pipelines configured)
- Custom health checks (if provided)

You can also report health manually:

```elixir
# Manual health report
ZyzyvaTelemetry.report_health(%{
  status: :degraded,
  reason: "High memory usage",
  memory_mb: 1024
})
```

#### Custom Health Checks

Add custom health checks via the `extra_health_checks` option:

```elixir
{ZyzyvaTelemetry.MonitoringSupervisor,
 service_name: "my_app",
 repo: MyApp.Repo,
 extra_health_checks: %{
   queue_depth: fn -> %{queue_depth: MyApp.Queue.depth()} end,
   cache_status: fn -> %{cache_hit_rate: MyApp.Cache.hit_rate()} end
 }}
```

## Testing

The setup task generates a test helper module and configures your test environment automatically. The test helper provides reusable assertions for testing health endpoints.

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

## Configuration Options

The MonitoringSupervisor accepts these options:

- `service_name` - Application name (required, defaults to Mix.Project app name)
- `repo` - Ecto repo module for database health checks (optional)
- `broadway_pipelines` - List of Broadway pipeline modules to monitor (optional)
- `extra_health_checks` - Map of custom health check functions (optional)
- `health_interval_ms` - Health check interval in milliseconds (default: 30_000)
- `db_path` - Database path (default: `/var/lib/monitoring/events.db`)
- `node_id` - Node identifier (defaults to `node()`)

## Data Management

The library writes events to a shared SQLite database that grows over time. Data retention and cleanup should be handled by a separate aggregator service (not included) that:

1. Reads unforwarded events from the database
2. Forwards them to central monitoring
3. Marks events as forwarded using `SqliteWriter.mark_events_forwarded/2`
4. Deletes old forwarded events periodically
5. Runs VACUUM to reclaim disk space

Without an aggregator, expect approximately:
- 10 services: ~24 MB/day
- 50 services: ~120 MB/day
- 100 services: ~240 MB/day

## Architecture

ZyzyvaTelemetry uses a local-first architecture with these key components:

- **MonitoringSupervisor** - Main OTP supervisor that manages all monitoring processes
- **HealthReporter** - GenServer that periodically collects and reports health metrics
- **ErrorLogger** - Centralized error and warning logging with correlation support
- **SqliteWriter** - Direct SQLite operations with support for forwarding markers
- **Correlation** - Process-dictionary based correlation ID tracking

The library writes all monitoring data to a local SQLite database that is shared by all applications on the server. A separate aggregator service (not included) can forward this data to a central monitoring system.

### Database Performance

The SQLite database at `/var/lib/monitoring/events.db` is optimized for concurrent access:

- **WAL mode** - Write-Ahead Logging for better concurrency (readers don't block writers)
- **NORMAL synchronous** - Safe with WAL, better performance than FULL
- **10MB cache** - Reduced disk I/O for frequently accessed data
- **Memory-mapped I/O** - Up to 256MB for faster access
- **Proper indexes** - Efficient queries on forwarded status, timestamps, and correlation IDs

