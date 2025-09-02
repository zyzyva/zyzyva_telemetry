defmodule ZyzyvaTelemetry.ErrorLogger do
  @moduledoc """
  Module for logging errors and warnings to the monitoring database.
  Must be configured before use with service information.
  """

  alias ZyzyvaTelemetry.SqliteWriter

  # Use a module attribute to store configuration
  @config_key :zyzyva_telemetry_error_logger_config

  @doc """
  Configures the error logger with service information.

  Config options:
  - service_name: Name of the service (required)
  - node_id: Node identifier (required)
  - db_path: Path to SQLite database (optional - if nil, database writes are skipped)
  """
  def configure(config) do
    :persistent_term.put(@config_key, config)
    :ok
  end

  @doc """
  Clears the error logger configuration.
  """
  def clear_configuration do
    :persistent_term.erase(@config_key)
    :ok
  end

  @doc """
  Logs an error message.
  """
  def log_error(message) do
    log_error(message, %{}, nil)
  end

  @doc """
  Logs an error message with metadata.
  """
  def log_error(message, metadata) do
    log_error(message, metadata, nil)
  end

  @doc """
  Logs an error message with metadata and correlation ID.
  """
  def log_error(message, metadata, correlation_id) do
    case get_config() do
      {:ok, config} ->
        if config.db_path do
          # Use provided correlation_id or get from process dictionary
          final_correlation_id = correlation_id || ZyzyvaTelemetry.Correlation.get()
          event = build_error_event(config, message, "error", metadata, final_correlation_id)
          SqliteWriter.write_event(config.db_path, event)
        else
          :ok
        end

      {:error, :not_configured} ->
        {:error, :not_configured}
    end
  end

  @doc """
  Logs a warning message.
  """
  def log_warning(message) do
    log_warning(message, %{})
  end

  @doc """
  Logs a warning message with metadata.
  """
  def log_warning(message, metadata) do
    case get_config() do
      {:ok, config} ->
        if config.db_path do
          event = build_error_event(config, message, "warning", metadata, nil)
          SqliteWriter.write_event(config.db_path, event)
        else
          :ok
        end

      {:error, :not_configured} ->
        {:error, :not_configured}
    end
  end

  @doc """
  Logs an exception with stack trace.
  """
  def log_exception(exception, stacktrace, message) do
    log_exception(exception, stacktrace, message, %{})
  end

  @doc """
  Logs an exception with stack trace and additional metadata.
  """
  def log_exception(exception, stacktrace, message, additional_metadata) do
    case get_config() do
      {:ok, config} ->
        if config.db_path do
          # Extract exception details
          exception_type = exception.__struct__ |> Module.split() |> List.last()
          exception_message = Exception.message(exception)

          # Format stack trace
          formatted_stacktrace =
            Exception.format_stacktrace(stacktrace)
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          # Build metadata
          metadata =
            Map.merge(additional_metadata, %{
              error_type: exception_type,
              error_message: exception_message,
              stacktrace: formatted_stacktrace
            })

          # Build full message
          full_message = "#{message}: #{inspect(exception)}"

          event = build_error_event(config, full_message, "error", metadata, nil)
          SqliteWriter.write_event(config.db_path, event)
        else
          :ok
        end

      {:error, :not_configured} ->
        {:error, :not_configured}
    end
  end

  # Private functions

  defp get_config do
    try do
      config = :persistent_term.get(@config_key)
      {:ok, config}
    rescue
      ArgumentError -> {:error, :not_configured}
    end
  end

  defp build_error_event(config, message, severity, metadata, correlation_id) do
    %{
      service_name: config.service_name,
      node_id: config.node_id,
      event_type: "error",
      severity: severity,
      message: message,
      correlation_id: correlation_id,
      metadata: metadata
    }
  end
end
