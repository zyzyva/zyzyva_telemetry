defmodule ZyzyvaTelemetry.LokiLogger do
  @moduledoc """
  Logger handler that buffers and pushes log messages to Loki.

  Registers as an Erlang `:logger` handler and batches messages for
  efficient delivery. No Promtail needed — logs go straight from your
  application to Loki over HTTP.

  ## Setup

  Add to your ZyzyvaTelemetry supervisor opts (it starts automatically):

      config :zyzyva_telemetry, ZyzyvaTelemetry.LokiLogger,
        loki_url: "http://loki:3100",
        service_name: "my_app",
        min_level: :warning,       # optional, default :warning
        flush_interval: 5_000,     # optional, ms between flushes
        max_buffer_size: 100       # optional, flush when buffer hits this

  Then ensure `LOKI_URL` is set (or configure loki_url directly).

  ## Querying

  Logs are pushed with `{job="logs", service="my_app", level="error"}` labels.
  Query in Grafana/Loki:

      {job="logs", service="church_voter_guides"}
      {job="logs", level="error"}
  """

  use GenServer

  require Logger

  @default_flush_interval 5_000
  @default_max_buffer_size 100
  @default_min_level :warning
  @handler_id :zyzyva_loki_logger

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # ============================================================================
  # Erlang :logger handler callbacks
  # Called by the logger framework in the caller's process.
  # ============================================================================

  def log(log_event, %{config: %{server: server}}) do
    GenServer.cast(server, {:log, log_event})
  end

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_set_or_update, _old, new), do: {:ok, new}

  # ============================================================================
  # GenServer callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    loki_url = opts[:loki_url]
    service_name = opts[:service_name] || "unknown"
    min_level = opts[:min_level] || @default_min_level
    flush_interval = opts[:flush_interval] || @default_flush_interval
    max_buffer_size = opts[:max_buffer_size] || @default_max_buffer_size

    # Register as an Erlang :logger handler
    handler_config = %{
      level: min_level,
      config: %{server: __MODULE__},
      filter_default: :log,
      filters: []
    }

    case :logger.add_handler(@handler_id, __MODULE__, handler_config) do
      :ok ->
        :ok

      {:error, {:already_exist, @handler_id}} ->
        :logger.remove_handler(@handler_id)
        :logger.add_handler(@handler_id, __MODULE__, handler_config)
    end

    schedule_flush(flush_interval)

    {:ok,
     %{
       loki_url: loki_url,
       service_name: service_name,
       buffer: [],
       buffer_size: 0,
       max_buffer_size: max_buffer_size,
       flush_interval: flush_interval
     }}
  end

  @impl GenServer
  def handle_cast({:log, log_event}, state) do
    entry = format_entry(log_event, state.service_name)
    new_state = %{state | buffer: [entry | state.buffer], buffer_size: state.buffer_size + 1}

    if new_state.buffer_size >= new_state.max_buffer_size do
      do_flush(new_state)
    else
      {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info(:flush, state) do
    schedule_flush(state.flush_interval)
    do_flush(state)
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :logger.remove_handler(@handler_id)
    :ok
  end

  # ============================================================================
  # Flushing
  # ============================================================================

  defp do_flush(%{buffer: []} = state), do: {:noreply, state}

  defp do_flush(%{buffer: buffer, loki_url: loki_url, service_name: service_name} = state) do
    entries = Enum.reverse(buffer)

    Task.start(fn ->
      push_to_loki(loki_url, service_name, entries)
    end)

    {:noreply, %{state | buffer: [], buffer_size: 0}}
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush, interval)
  end

  # ============================================================================
  # Loki formatting
  # ============================================================================

  defp format_entry(log_event, service_name) do
    level = Map.get(log_event, :level, :info) |> to_string()
    meta = Map.get(log_event, :meta, %{})
    timestamp_ns = system_time_ns(meta)

    message = format_message(log_event)

    log_line =
      %{
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        service: service_name,
        level: level,
        message: message,
        module: meta[:mfa] |> format_mfa(),
        file: meta[:file] |> to_string_safe(),
        line: meta[:line],
        pid: meta[:pid] |> inspect_safe(),
        request_id: meta[:request_id],
        correlation_id: get_correlation_id(),
        node: Node.self() |> to_string()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    %{level: level, timestamp_ns: timestamp_ns, log_line: log_line}
  end

  defp format_message(%{msg: {:string, chardata}}), do: IO.chardata_to_string(chardata)

  defp format_message(%{msg: {:report, report}}) when is_map(report) do
    inspect(report, limit: 500)
  end

  defp format_message(%{msg: {:report, report}}) when is_list(report) do
    inspect(report, limit: 500)
  end

  defp format_message(%{msg: {format, args}}) when is_list(format) or is_binary(format) do
    :io_lib.format(format, args) |> IO.chardata_to_string()
  rescue
    _ -> "#{inspect(format)} #{inspect(args)}"
  end

  defp format_message(_), do: "unknown log message"

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(_), do: nil

  defp to_string_safe(nil), do: nil
  defp to_string_safe(val) when is_binary(val), do: val
  defp to_string_safe(val) when is_list(val), do: IO.chardata_to_string(val)
  defp to_string_safe(val), do: inspect(val)

  defp inspect_safe(nil), do: nil
  defp inspect_safe(val), do: inspect(val)

  defp system_time_ns(%{time: time}), do: to_string(time * 1000)
  defp system_time_ns(_), do: System.os_time(:nanosecond) |> to_string()

  defp get_correlation_id do
    ZyzyvaTelemetry.Correlation.current()
  rescue
    _ -> nil
  end

  # ============================================================================
  # Loki push
  # ============================================================================

  defp push_to_loki(nil, _service_name, _entries), do: :ok

  defp push_to_loki(loki_url, service_name, entries) do
    # Group entries by level into separate Loki streams
    streams =
      entries
      |> Enum.group_by(& &1.level)
      |> Enum.map(fn {level, level_entries} ->
        values = Enum.map(level_entries, fn e -> [e.timestamp_ns, JSON.encode!(e.log_line)] end)

        %{
          stream: %{
            job: "logs",
            service: service_name,
            level: level
          },
          values: values
        }
      end)

    payload = %{streams: streams}
    url = "#{loki_url}/loki/api/v1/push"

    case Req.post(url, json: payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("LokiLogger: push failed HTTP #{status}: #{inspect(body)}")
        :error

      {:error, reason} ->
        Logger.warning("LokiLogger: push failed: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("LokiLogger: exception during push: #{inspect(error)}")
      :error
  end
end
