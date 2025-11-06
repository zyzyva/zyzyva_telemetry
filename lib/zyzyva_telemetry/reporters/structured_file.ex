defmodule ZyzyvaTelemetry.Reporters.StructuredFile do
  @moduledoc """
  Writes errors as structured JSON logs for Loki/Promtail ingestion.
  Each error is written as a single JSON line.
  """

  @behaviour Tower.Reporter

  @impl Tower.Reporter
  def report_event(event) do
    opts = Process.get(:tower_reporter_opts, [])

    log_entry = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: opts[:service_name],
      level: event_level(event),
      kind: event_kind(event),
      message: event_message(event),
      stacktrace: event_stacktrace(event),
      correlation_id: get_correlation_id(),
      metadata: Map.get(event, :metadata, %{}),
      node: Node.self() |> to_string()
    }

    log_path = opts[:log_path]

    if log_path do
      # Ensure directory exists
      log_path |> Path.dirname() |> File.mkdir_p!()

      # Append JSON line to log file
      # Use native JSON module (Elixir 1.18+)
      File.write!(log_path, JSON.encode!(log_entry) <> "\n", [:append])
    end

    :ok
  end

  defp event_level(%{level: level}), do: to_string(level)
  defp event_level(_), do: "ERROR"

  defp event_kind(%{kind: kind}), do: to_string(kind)
  defp event_kind(_), do: "unknown"

  defp event_message(%{reason: reason}) when is_exception(reason) do
    Exception.message(reason)
  end

  defp event_message(%{message: message}), do: message
  defp event_message(_), do: "Unknown error"

  defp event_stacktrace(%{stacktrace: stacktrace}) when is_list(stacktrace) do
    Exception.format_stacktrace(stacktrace)
  end

  defp event_stacktrace(_), do: nil

  defp get_correlation_id do
    ZyzyvaTelemetry.Correlation.current()
  end
end
