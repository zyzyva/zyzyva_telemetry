defmodule ZyzyvaTelemetry do
  @moduledoc """
  ZyzyvaTelemetry is a lightweight monitoring library for distributed Elixir applications.

  It provides:
  - Local-first error and event logging to SQLite
  - Automatic health reporting
  - Correlation ID tracking for distributed tracing
  - Zero network latency for monitoring operations

  ## Usage

  Initialize the telemetry system in your application startup:

      config = %{
        service_name: "my_service",
        db_path: "/var/lib/monitoring/events.db",  # Optional, uses default
        health_check_fn: &MyApp.custom_health_check/0  # Optional
      }
      
      ZyzyvaTelemetry.init(config)

  Then use throughout your application:

      # Log errors
      ZyzyvaTelemetry.log_error("Failed to process", %{user_id: 123})
      
      # Track correlation across services
      ZyzyvaTelemetry.with_correlation(correlation_id, fn ->
        # Your code here - all logs will include correlation_id
      end)
  """

  alias ZyzyvaTelemetry.{SqliteWriter, HealthReporter, ErrorLogger, Correlation}

  @default_db_path "/var/lib/monitoring/events.db"
  @fallback_db_path "/tmp/monitoring/events.db"

  @doc """
  Initializes the ZyzyvaTelemetry system.

  Options:
  - service_name: Name of your service (required)
  - db_path: Path to SQLite database (optional, defaults to /var/lib/monitoring/events.db)
  - node_id: Node identifier (optional, defaults to hostname)
  - health_check_fn: Function that returns health data (optional)
  - health_interval_ms: Health reporting interval (optional, defaults to 30000)
  """
  def init(config) do
    # Determine database path
    db_path = config[:db_path] || determine_db_path()

    # Get or generate node_id
    {:ok, hostname} = :inet.gethostname()
    node_id = config[:node_id] || to_string(hostname)

    # Initialize database
    {:ok, _} = SqliteWriter.init_database(db_path)

    # Configure error logger
    error_config = %{
      service_name: config.service_name,
      node_id: node_id,
      db_path: db_path
    }

    ErrorLogger.configure(error_config)

    # Start health reporter if not already running
    case Process.whereis(:zyzyva_telemetry_health_reporter) do
      nil ->
        health_config = %{
          service_name: config.service_name,
          node_id: node_id,
          db_path: db_path,
          interval_ms: config[:health_interval_ms] || 30_000,
          health_check_fn: config[:health_check_fn]
        }

        {:ok, pid} = HealthReporter.start_link(health_config)
        Process.register(pid, :zyzyva_telemetry_health_reporter)

      _pid ->
        # Already running, skip
        :ok
    end

    :ok
  end

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

  # Private functions

  defp determine_db_path do
    cond do
      File.exists?(Path.dirname(@default_db_path)) ->
        @default_db_path

      true ->
        # Use fallback path and ensure directory exists
        dir = Path.dirname(@fallback_db_path)
        File.mkdir_p!(dir)
        @fallback_db_path
    end
  end
end
