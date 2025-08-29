#!/usr/bin/env elixir

# Debug script to check monitoring event flow

IO.puts "\n=== Monitoring Debug Script ===\n"

# 1. Check if SQLite database exists and has events
db_path = Path.expand("~/.zyzyva/monitoring.db")
IO.puts "1. Checking SQLite database at: #{db_path}"

if File.exists?(db_path) do
  IO.puts "   ✓ Database file exists"
  
  # Get database stats
  case ZyzyvaTelemetry.SqliteWriter.get_database_stats(db_path) do
    {:ok, stats} ->
      IO.puts "   Database Stats:"
      IO.puts "   - Total events: #{stats.total_events}"
      IO.puts "   - Forwarded events: #{stats.forwarded_events}"
      IO.puts "   - Unforwarded events: #{stats.unforwarded_events}"
      IO.puts "   - Database size: #{stats.database_size_bytes} bytes"
      
    {:error, reason} ->
      IO.puts "   ✗ Error getting stats: #{inspect(reason)}"
  end
  
  # Check for recent unforwarded events
  case ZyzyvaTelemetry.SqliteWriter.get_unforwarded_events(db_path, 10) do
    {:ok, events} ->
      IO.puts "   - Recent unforwarded events: #{length(events)}"
      if length(events) > 0 do
        IO.puts "   - Sample event: #{inspect(List.first(events), pretty: true, limit: :infinity)}"
      end
    {:error, reason} ->
      IO.puts "   ✗ Error reading events: #{inspect(reason)}"
  end
else
  IO.puts "   ✗ Database file does not exist!"
end

# 2. Check if monitoring processes are running
IO.puts "\n2. Checking monitoring processes:"

# Check if MonitoringAggregator is running (in infrastructure-automation)
aggregator_running = Process.whereis(:monitoring_aggregator) != nil
IO.puts "   - MonitoringAggregator: #{if aggregator_running, do: "✓ Running", else: "✗ Not running"}"

# Check if AppMonitoring is running
app_monitoring = Process.whereis(ZyzyvaTelemetry.AppMonitoring) != nil
IO.puts "   - AppMonitoring: #{if app_monitoring, do: "✓ Running", else: "✗ Not running"}"

# Check if HealthReporter is running  
health_reporter = Process.whereis(ZyzyvaTelemetry.HealthReporter) != nil
IO.puts "   - HealthReporter: #{if health_reporter, do: "✓ Running", else: "✗ Not running"}"

# 3. Generate a test event and track it
IO.puts "\n3. Generating and tracking test event:"
test_event = %{
  service_name: "debug_test",
  node_id: node(),
  event_type: "test",
  severity: "info",
  message: "Debug test event at #{DateTime.utc_now()}",
  correlation_id: "debug_#{System.unique_integer([:positive])}",
  metadata: %{source: "debug_script"}
}

case ZyzyvaTelemetry.SqliteWriter.write_event(db_path, test_event) do
  :ok ->
    IO.puts "   ✓ Test event written successfully"
    IO.puts "   Correlation ID: #{test_event.correlation_id}"
  error ->
    IO.puts "   ✗ Failed to write test event: #{inspect(error)}"
end

# 4. Check configuration
IO.puts "\n4. Checking configuration:"
config = Application.get_all_env(:zyzyva_telemetry)
IO.puts "   Monitoring enabled: #{config[:monitoring_enabled]}"
IO.puts "   Database path: #{config[:db_path]}"
IO.puts "   Service name: #{config[:service_name]}"

# 5. Try to manually trigger aggregation if in infrastructure-automation
IO.puts "\n5. Checking aggregation:"
if Code.ensure_loaded?(InfrastructureAutomation.MonitoringAggregator) do
  IO.puts "   MonitoringAggregator module is loaded"
  
  # Check if it's running
  case GenServer.whereis(InfrastructureAutomation.MonitoringAggregator) do
    nil ->
      IO.puts "   ✗ MonitoringAggregator GenServer is not running"
    pid ->
      IO.puts "   ✓ MonitoringAggregator is running at #{inspect(pid)}"
      
      # Get stats
      stats = GenServer.call(pid, :get_stats)
      IO.puts "   Aggregator stats: #{inspect(stats, pretty: true)}"
      
      # Trigger aggregation
      IO.puts "   Triggering manual aggregation..."
      GenServer.cast(pid, :aggregate_now)
      Process.sleep(1000)
      IO.puts "   ✓ Aggregation triggered"
  end
else
  IO.puts "   - MonitoringAggregator module not available (not in infrastructure-automation app)"
end

# 6. Check RabbitMQ connection (if available)
IO.puts "\n6. Checking RabbitMQ:"
if Code.ensure_loaded?(InfrastructureAutomation.RabbitMQPublisher) do
  connected = InfrastructureAutomation.RabbitMQPublisher.connected?()
  IO.puts "   RabbitMQ Publisher: #{if connected, do: "✓ Connected", else: "✗ Not connected"}"
else
  IO.puts "   - RabbitMQ Publisher not available (not in infrastructure-automation app)"
end

IO.puts "\n=== Debug Complete ===\n"