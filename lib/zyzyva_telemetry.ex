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

end
