defmodule ZyzyvaTelemetry.TestGenerator do
  @moduledoc """
  Test event generator for QA and testing purposes.

  This module provides functions to generate various types of monitoring events
  to test the full telemetry pipeline from app to dashboard.
  """

  require Logger
  alias ZyzyvaTelemetry.SqliteWriter

  @event_types [
    {"http_request", "info"},
    {"database_query", "info"},
    {"cache_miss", "warning"},
    {"slow_query", "warning"},
    {"connection_error", "error"},
    {"timeout", "error"},
    {"memory_spike", "warning"},
    {"authentication_failure", "error"},
    {"rate_limit_exceeded", "warning"},
    {"service_unavailable", "critical"}
  ]

  @doc """
  Generates a batch of test monitoring events.

  ## Options
    * `:count` - Number of events to generate (default: 10)
    * `:service_name` - Override the service name (default: uses app name)
    * `:include_errors` - Whether to include error events (default: true)
    * `:include_critical` - Whether to include critical events (default: false)
  """
  def generate_test_events(opts \\ []) do
    count = Keyword.get(opts, :count, 10)
    service_name = Keyword.get(opts, :service_name, get_app_name())
    include_errors = Keyword.get(opts, :include_errors, true)
    include_critical = Keyword.get(opts, :include_critical, false)

    Logger.info("Generating #{count} test monitoring events for service: #{service_name}")

    events =
      1..count
      |> Enum.map(fn i ->
        {event_type, severity} = select_event_type(include_errors, include_critical)

        # Build proper event structure matching real events
        event = %{
          service_name: service_name,
          node_id: node() |> to_string(),
          event_type: event_type,
          severity: severity,
          message: "Test #{event_type} event ##{i}",
          correlation_id: __MODULE__.UUID.uuid4(),
          metadata: %{
            test_event: true,
            test_batch_id: generate_batch_id(),
            test_sequence: i,
            additional_info: "Test event generated at #{DateTime.utc_now()}"
          }
        }

        # Get the configured db_path
        db_path =
          Application.get_env(:zyzyva_telemetry, :db_path, "/var/lib/monitoring/events.db")

        # Write to SQLite via SqliteWriter
        case SqliteWriter.write_event(db_path, event) do
          :ok ->
            Logger.debug("Test event #{i} written: #{event_type} (#{severity})")
            {:ok, event}

          {:error, reason} ->
            Logger.error("Failed to write test event #{i}: #{inspect(reason)}")
            {:error, reason}
        end
      end)

    successful = Enum.count(events, fn {status, _} -> status == :ok end)
    failed = Enum.count(events, fn {status, _} -> status == :error end)

    summary = %{
      total_requested: count,
      successful: successful,
      failed: failed,
      service_name: service_name,
      timestamp: DateTime.utc_now()
    }

    Logger.info("Test event generation complete: #{successful} successful, #{failed} failed")

    {:ok, summary}
  end

  @doc """
  Generates a critical incident for testing alerts.

  This will generate a series of critical and error events to trigger
  alerting in the monitoring dashboard.
  """
  def generate_critical_incident(service_name \\ nil) do
    service = service_name || get_app_name()

    Logger.warning("Generating CRITICAL INCIDENT for service: #{service}")

    # Generate a sequence of escalating events
    events = [
      # Start with warnings
      %{event_type: "memory_spike", severity: "warning", count: 3},
      %{event_type: "slow_query", severity: "warning", count: 5},
      # Escalate to errors
      %{event_type: "timeout", severity: "error", count: 10},
      %{event_type: "connection_error", severity: "error", count: 15},
      # Critical event
      %{event_type: "service_unavailable", severity: "critical", count: 1}
    ]

    batch_id = generate_batch_id()

    db_path = Application.get_env(:zyzyva_telemetry, :db_path, "/var/lib/monitoring/events.db")

    Enum.each(events, fn %{event_type: type, severity: sev, count: cnt} ->
      1..cnt
      |> Enum.each(fn i ->
        event = %{
          service_name: service,
          node_id: node() |> to_string(),
          event_type: type,
          severity: sev,
          message: "Critical incident simulation: #{type}",
          correlation_id: __MODULE__.UUID.uuid4(),
          metadata: %{
            test_event: true,
            test_incident: true,
            test_batch_id: batch_id,
            incident_sequence: i,
            error_message: "Simulated #{sev} event for testing",
            stack_trace:
              if(sev in ["error", "critical"], do: generate_fake_stacktrace(), else: nil)
          }
        }

        SqliteWriter.write_event(db_path, event)
        # Small delay to simulate real incident timing
        Process.sleep(50)
      end)
    end)

    Logger.warning("Critical incident simulation complete for #{service}")

    {:ok,
     %{
       service_name: service,
       batch_id: batch_id,
       events_generated: Enum.sum(Enum.map(events, & &1.count)),
       timestamp: DateTime.utc_now()
     }}
  end

  @doc """
  Triggers REAL monitoring events through the actual error logging system.
  This is the most realistic test as it uses the same code path as production errors.
  """
  def trigger_real_errors(opts \\ []) do
    count = Keyword.get(opts, :count, 5)
    include_exception = Keyword.get(opts, :include_exception, true)

    Logger.info("Triggering #{count} REAL monitoring events through error logger")

    1..count
    |> Enum.each(fn i ->
      # Set a correlation ID for this batch of operations
      correlation_id = __MODULE__.UUID.uuid4()
      ZyzyvaTelemetry.set_correlation(correlation_id)

      # Log various types of real events
      case rem(i, 4) do
        0 ->
          # Log an error
          ZyzyvaTelemetry.log_error("Database connection failed", %{
            attempt: i,
            database: "test_db",
            error_code: "ECONNREFUSED"
          })

        1 ->
          # Log a warning
          ZyzyvaTelemetry.log_warning("Memory usage high", %{
            memory_mb: 512 + i * 10,
            threshold_mb: 500
          })

        2 ->
          # Log an exception (if enabled)
          if include_exception do
            try do
              # Intentionally cause an error
              raise "Test exception for monitoring"
            rescue
              e ->
                ZyzyvaTelemetry.log_exception(e, __STACKTRACE__, "Test operation failed", %{
                  operation: "test_operation_#{i}",
                  test_run: true
                })
            end
          else
            ZyzyvaTelemetry.log_error("Simulated exception", %{
              error_type: "RuntimeError",
              operation: "test_operation_#{i}"
            })
          end

        3 ->
          # Log with correlation context
          ZyzyvaTelemetry.with_correlation("test-request-#{i}", fn ->
            ZyzyvaTelemetry.log_error("Request processing failed", %{
              request_id: "test-request-#{i}",
              status_code: 500,
              latency_ms: 1500
            })
          end)
      end

      # Small delay between events
      Process.sleep(100)
    end)

    Logger.info("Real error triggering complete")

    {:ok,
     %{
       events_triggered: count,
       timestamp: DateTime.utc_now()
     }}
  end

  @doc """
  Generates a performance degradation scenario.
  """
  def generate_performance_degradation(duration_seconds \\ 30) do
    service = get_app_name()

    Logger.info("Starting performance degradation simulation for #{duration_seconds} seconds")

    Task.start(fn ->
      end_time = System.monotonic_time(:second) + duration_seconds
      db_path = Application.get_env(:zyzyva_telemetry, :db_path, "/var/lib/monitoring/events.db")

      generate_performance_events(end_time, service, db_path)

      Logger.info("Performance degradation simulation completed")
    end)

    {:ok, %{duration: duration_seconds, service: service}}
  end

  # Private functions

  defp generate_performance_events(end_time, service, db_path) do
    if System.monotonic_time(:second) < end_time do
      # Generate increasingly slow queries
      # 1-6 second queries
      latency = :rand.uniform(5000) + 1000

      event = %{
        service_name: service,
        node_id: node() |> to_string(),
        event_type: "slow_query",
        severity: if(latency > 3000, do: "warning", else: "info"),
        message: "Query took #{latency}ms to complete",
        correlation_id: __MODULE__.UUID.uuid4(),
        metadata: %{
          test_event: true,
          performance_test: true,
          query_latency_ms: latency,
          query: "SELECT * FROM large_table WHERE complex_conditions"
        }
      }

      SqliteWriter.write_event(db_path, event)
      # Random delay between events
      Process.sleep(:rand.uniform(1000))

      # Recursive call
      generate_performance_events(end_time, service, db_path)
    end
  end

  defp get_app_name do
    Application.get_env(:zyzyva_telemetry, :app_name) ||
      to_string(Application.get_application(__MODULE__)) ||
      "test_app"
  end

  defp select_event_type(include_errors, include_critical) do
    available_types =
      @event_types
      |> Enum.filter(fn {_, severity} ->
        cond do
          severity == "critical" -> include_critical
          severity == "error" -> include_errors
          true -> true
        end
      end)

    Enum.random(available_types)
  end

  defp generate_batch_id do
    :crypto.strong_rand_bytes(8)
    |> Base.hex_encode32(case: :lower)
    |> String.slice(0..7)
  end

  defp generate_fake_stacktrace do
    """
    ** (RuntimeError) Simulated test error
        (test_app 0.1.0) lib/test_app/worker.ex:42: TestApp.Worker.process/1
        (test_app 0.1.0) lib/test_app/supervisor.ex:18: TestApp.Supervisor.handle_call/3
        (stdlib 5.0) gen_server.erl:1113: :gen_server.call/3
    """
  end

  # UUID v4 generator (simplified)
  defmodule UUID do
    def uuid4 do
      :crypto.strong_rand_bytes(16)
      |> Base.hex_encode32(case: :lower)
      |> String.slice(0..31)
      |> format_uuid()
    end

    defp format_uuid(hex) do
      <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
      "#{a}-#{b}-#{c}-#{d}-#{e}"
    end
  end
end
