defmodule ZyzyvaTelemetry.Reporters.Loki do
  @moduledoc """
  Pushes errors directly to Loki via HTTP API.
  No Promtail needed - logs go straight from application to Loki.

  Configure via Application env:

      config :zyzyva_telemetry, ZyzyvaTelemetry.Reporters.Loki,
        loki_url: "http://loki:3100",
        service_name: "my_app"

  Then add the module to Tower's reporters list:

      config :tower, reporters: [ZyzyvaTelemetry.Reporters.Loki]

  Loki Push API format:
  https://grafana.com/docs/loki/latest/api/#push-log-entries-to-loki
  """

  @behaviour Tower.Reporter

  require Logger

  @impl Tower.Reporter
  def report_event(event) do
    opts = Application.get_env(:zyzyva_telemetry, __MODULE__, [])

    loki_url = opts[:loki_url]
    service_name = opts[:service_name]

    if is_nil(loki_url) do
      Logger.warning("Loki URL not configured, skipping error report")
      :ok
    else
      log_entry = build_log_entry(event, service_name)

      # Push to Loki asynchronously to avoid blocking the application
      Task.start(fn ->
        push_to_loki(loki_url, log_entry)
      end)

      :ok
    end
  end

  defp build_log_entry(event, service_name) do
    timestamp_ns = System.os_time(:nanosecond) |> to_string()

    # Build log line as JSON string (Loki expects the log line as a string)
    log_line = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      service: service_name,
      level: event_level(event),
      kind: event_kind(event),
      message: event_message(event),
      stacktrace: event_stacktrace(event),
      correlation_id: get_correlation_id(),
      metadata: event |> Map.get(:metadata, %{}) |> sanitize_for_json(),
      node: Node.self() |> to_string()
    }
    |> JSON.encode!()

    # Loki stream format with labels
    %{
      streams: [
        %{
          stream: %{
            job: "errors",
            service: service_name || "unknown",
            level: event_level(event),
            kind: event_kind(event)
          },
          values: [
            [timestamp_ns, log_line]
          ]
        }
      ]
    }
  end

  defp push_to_loki(loki_url, payload) do
    url = "#{loki_url}/loki/api/v1/push"

    case Req.post(url, json: payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to push to Loki: HTTP #{status}, body: #{inspect(body)}")
        :error

      {:error, reason} ->
        Logger.error("Failed to push to Loki: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.error("Exception pushing to Loki: #{inspect(error)}")
      :error
  end

  defp event_level(%{level: level}), do: to_string(level)
  defp event_level(_), do: "ERROR"

  defp event_kind(%{kind: kind}), do: to_string(kind)
  defp event_kind(_), do: "unknown"

  defp event_message(%{reason: reason}) when is_exception(reason) do
    Exception.message(reason)
  end
  defp event_message(%{reason: reason}) when is_binary(reason), do: reason
  defp event_message(%{message: message}), do: message
  defp event_message(_), do: "Unknown error"

  defp event_stacktrace(%{stacktrace: stacktrace}) when is_list(stacktrace) do
    Exception.format_stacktrace(stacktrace)
  end
  defp event_stacktrace(_), do: nil

  defp get_correlation_id do
    case ZyzyvaTelemetry.Correlation.current() do
      nil -> nil
      correlation_id -> correlation_id
    end
  end

  defp sanitize_for_json(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, sanitize_for_json(v)} end)
  end

  defp sanitize_for_json(value) when is_list(value) do
    Enum.map(value, &sanitize_for_json/1)
  end

  defp sanitize_for_json(value) when is_pid(value), do: inspect(value)
  defp sanitize_for_json(value) when is_port(value), do: inspect(value)
  defp sanitize_for_json(value) when is_reference(value), do: inspect(value)
  defp sanitize_for_json(value) when is_function(value), do: inspect(value)

  defp sanitize_for_json(value) when is_tuple(value) do
    value |> Tuple.to_list() |> sanitize_for_json()
  end

  defp sanitize_for_json(value), do: value
end
