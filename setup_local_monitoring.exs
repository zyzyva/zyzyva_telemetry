#!/usr/bin/env elixir

# Setup script for local monitoring testing

IO.puts "\n=== Setting up Local Monitoring ===\n"

# 1. Set configuration
db_path = Path.expand("~/.zyzyva/monitoring.db")
IO.puts "1. Setting configuration..."
Application.put_env(:zyzyva_telemetry, :monitoring_enabled, true)
Application.put_env(:zyzyva_telemetry, :db_path, db_path)
Application.put_env(:zyzyva_telemetry, :service_name, "zyzyva_telemetry")
IO.puts "   ✓ Configuration set"

# 2. Create database directory
db_dir = Path.dirname(db_path)
IO.puts "\n2. Creating database directory: #{db_dir}"
File.mkdir_p!(db_dir)
IO.puts "   ✓ Directory created"

# 3. Initialize database
IO.puts "\n3. Initializing database..."
case ZyzyvaTelemetry.SqliteWriter.init_database(db_path) do
  {:ok, _} ->
    IO.puts "   ✓ Database initialized"
  {:error, reason} ->
    IO.puts "   ✗ Failed to initialize database: #{inspect(reason)}"
    System.halt(1)
end

# 4. Start monitoring supervisor
IO.puts "\n4. Starting monitoring processes..."
case ZyzyvaTelemetry.MonitoringSupervisor.start_link(
  db_path: db_path,
  service_name: "zyzyva_telemetry",
  monitoring_enabled: true
) do
  {:ok, pid} ->
    IO.puts "   ✓ MonitoringSupervisor started: #{inspect(pid)}"
  {:error, {:already_started, pid}} ->
    IO.puts "   ✓ MonitoringSupervisor already running: #{inspect(pid)}"
  {:error, reason} ->
    IO.puts "   ✗ Failed to start monitoring: #{inspect(reason)}"
end

# Wait a moment for processes to initialize
Process.sleep(500)

# 5. Verify everything is running
IO.puts "\n5. Verifying setup:"
IO.puts "   - Database exists: #{File.exists?(db_path)}"
IO.puts "   - AppMonitoring running: #{Process.whereis(ZyzyvaTelemetry.AppMonitoring) != nil}"
IO.puts "   - HealthReporter running: #{Process.whereis(ZyzyvaTelemetry.HealthReporter) != nil}"

# 6. Generate test events
IO.puts "\n6. Generating test events..."
result = ZyzyvaTelemetry.TestGenerator.generate_test_events(count: 10)
IO.inspect(result, label: "   Result")

# 7. Check database for events
Process.sleep(1000)
IO.puts "\n7. Checking database for events..."
case ZyzyvaTelemetry.SqliteWriter.get_database_stats(db_path) do
  {:ok, stats} ->
    IO.puts "   Database stats:"
    IO.puts "   - Total events: #{stats.total_events}"
    IO.puts "   - Unforwarded events: #{stats.unforwarded_events}"
  {:error, reason} ->
    IO.puts "   ✗ Error getting stats: #{inspect(reason)}"
end

IO.puts("\n=== Setup Complete ===")
IO.puts("\nMonitoring is now running. Events will be written to: #{db_path}")
IO.puts("To check the infrastructure-automation aggregator, run it with monitoring enabled.")
IO.puts("\n")