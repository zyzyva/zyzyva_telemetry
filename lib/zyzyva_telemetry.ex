defmodule ZyzyvaTelemetry do
  @moduledoc """
  ZyzyvaTelemetry is a lightweight monitoring library for distributed Elixir applications.

  It provides:
  - Local-first error and event logging to SQLite
  - Automatic health reporting
  - Correlation ID tracking for distributed tracing
  - Zero network latency for monitoring operations

  ## Usage

  Add to your application's supervision tree:

      children = [
        # ... other children
        {ZyzyvaTelemetry.MonitoringSupervisor,
         service_name: "my_app",
         repo: MyApp.Repo,
         broadway_pipelines: [MyApp.Pipeline.Broadway]}
      ]

  Then use throughout your application:

      # Log errors
      ZyzyvaTelemetry.log_error("Failed to process", %{user_id: 123})
      
      # Track correlation across services
      ZyzyvaTelemetry.with_correlation(correlation_id, fn ->
        # Your code here - all logs will include correlation_id
      end)
  """

  alias ZyzyvaTelemetry.{HealthReporter, ErrorLogger, Correlation}

  @doc """
  Logs an error message.
  """
  defdelegate log_error(message), to: ErrorLogger

  @doc """
  Logs an error message with metadata.
  """
  defdelegate log_error(message, metadata), to: ErrorLogger

  @doc """
  Logs an error with correlation ID from process dictionary.
  """
  def log_error(message, metadata, :with_correlation) do
    correlation_id = Correlation.get()
    ErrorLogger.log_error(message, metadata, correlation_id)
  end

  @doc """
  Logs a warning message.
  """
  defdelegate log_warning(message), to: ErrorLogger

  @doc """
  Logs a warning message with metadata.
  """
  defdelegate log_warning(message, metadata), to: ErrorLogger

  @doc """
  Logs an exception with stack trace.
  """
  defdelegate log_exception(exception, stacktrace, message), to: ErrorLogger

  @doc """
  Logs an exception with stack trace and metadata.
  """
  defdelegate log_exception(exception, stacktrace, message, metadata), to: ErrorLogger

  @doc """
  Manually reports health status.
  """
  def report_health(health_data) do
    case Process.whereis(:zyzyva_telemetry_health_reporter) do
      nil -> {:error, :health_reporter_not_running}
      pid -> HealthReporter.report_health(pid, health_data)
    end
  end

  @doc """
  Gets the current health status.
  """
  def get_health do
    case Process.whereis(:zyzyva_telemetry_health_reporter) do
      nil -> {:error, :health_reporter_not_running}
      pid -> HealthReporter.get_current_health(pid)
    end
  end

  @doc """
  Executes a function with a correlation ID set.
  """
  defdelegate with_correlation(correlation_id, fun), to: Correlation

  @doc """
  Gets the current correlation ID.
  """
  defdelegate get_correlation(), to: Correlation, as: :get

  @doc """
  Sets the correlation ID.
  """
  defdelegate set_correlation(correlation_id), to: Correlation, as: :set

  @doc """
  Generates a new correlation ID and sets it.
  """
  def new_correlation do
    correlation_id = Correlation.new()
    Correlation.set(correlation_id)
    correlation_id
  end

  @doc """
  Gets the current correlation ID or generates a new one.
  """
  defdelegate get_or_generate_correlation(), to: Correlation, as: :get_or_generate

  # Test Generation Functions (for QA and testing)

  @doc """
  Generates test monitoring events for QA purposes.

  This function is available at runtime in production releases.

  ## Options
    * `:count` - Number of events to generate (default: 10)
    * `:service_name` - Override the service name (default: uses app name)
    * `:include_errors` - Whether to include error events (default: true)
    * `:include_critical` - Whether to include critical events (default: false)

  ## Examples

      # Generate 10 test events
      ZyzyvaTelemetry.generate_test_events()
      
      # Generate 50 events with critical alerts
      ZyzyvaTelemetry.generate_test_events(count: 50, include_critical: true)
  """
  def generate_test_events(opts \\ []) do
    ensure_test_generator_loaded()
    apply(ZyzyvaTelemetry.TestGenerator, :generate_test_events, [opts])
  end

  @doc """
  Generates a critical incident simulation for testing alerts.

  This will generate a series of critical and error events to trigger
  alerting in the monitoring dashboard.

  ## Examples

      # Generate critical incident for current app
      ZyzyvaTelemetry.generate_critical_incident()
      
      # Generate for specific service
      ZyzyvaTelemetry.generate_critical_incident("api_gateway")
  """
  def generate_critical_incident(service_name \\ nil) do
    ensure_test_generator_loaded()
    apply(ZyzyvaTelemetry.TestGenerator, :generate_critical_incident, [service_name])
  end

  @doc """
  Generates a performance degradation scenario.

  ## Examples

      # Run 30-second performance test
      ZyzyvaTelemetry.generate_performance_degradation()
      
      # Run 60-second test
      ZyzyvaTelemetry.generate_performance_degradation(60)
  """
  def generate_performance_degradation(duration_seconds \\ 30) do
    ensure_test_generator_loaded()
    apply(ZyzyvaTelemetry.TestGenerator, :generate_performance_degradation, [duration_seconds])
  end

  @doc """
  Triggers REAL monitoring events through the actual error logging system.

  This is the most realistic test as it uses the same code path that production
  errors would use. It actually calls log_error, log_warning, and log_exception.

  ## Options
    * `:count` - Number of real errors to trigger (default: 5)
    * `:include_exception` - Whether to raise and catch real exceptions (default: true)

  ## Examples

      # Trigger 5 real errors
      ZyzyvaTelemetry.trigger_real_errors()
      
      # Trigger 10 real errors including exceptions
      ZyzyvaTelemetry.trigger_real_errors(count: 10, include_exception: true)
  """
  def trigger_real_errors(opts \\ []) do
    ensure_test_generator_loaded()
    apply(ZyzyvaTelemetry.TestGenerator, :trigger_real_errors, [opts])
  end

  # Ensure TestGenerator is loaded (it might be lazy-loaded in releases)
  defp ensure_test_generator_loaded do
    Code.ensure_loaded(ZyzyvaTelemetry.TestGenerator)
  end
end
