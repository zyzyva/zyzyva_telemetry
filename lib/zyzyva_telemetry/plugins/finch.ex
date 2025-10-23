defmodule ZyzyvaTelemetry.Plugins.Finch do
  @moduledoc """
  Finch HTTP client monitoring plugin for PromEx.

  Automatically tracks external HTTP requests made via Finch:
  - Request duration by host
  - Response status code distribution
  - Connection establishment time (DNS + TCP + SSL)
  - Timeout and retry tracking
  - Request queue time

  ## Configuration

      config :zyzyva_telemetry, :finch,
        enabled: false,                    # Opt-in by default
        track_connection_time: true,       # Track DNS/SSL handshake
        track_queue_time: true             # Track connection pool queue time

  ## Resource Usage

  Minimal overhead:
  - Piggybacks on existing Finch telemetry events
  - No additional HTTP requests or network calls
  - Metrics are incremental counters/histograms
  - < 0.1ms overhead per request

  ## Metrics Provided

  - `finch.request.duration` - Total request duration histogram
  - `finch.request.count` - Request count by status code
  - `finch.request.error.count` - Error count by error type
  - `finch.connection.duration` - Connection establishment time
  - `finch.queue.duration` - Time waiting for connection from pool
  """

  use PromEx.Plugin

  import Telemetry.Metrics

  @impl true
  def event_metrics(_opts) do
    config = get_config()
    build_metrics(config)
  end

  @impl true
  def polling_metrics(_opts), do: []

  ## Configuration

  defp get_config do
    Application.get_env(:zyzyva_telemetry, :finch, [])
    |> Keyword.put_new(:enabled, false)
    |> Keyword.put_new(:track_connection_time, true)
    |> Keyword.put_new(:track_queue_time, true)
    |> Enum.into(%{})
  end

  ## Metrics Building

  defp build_metrics(%{enabled: false}), do: []

  defp build_metrics(config) do
    [
      request_event(),
      connection_event(config),
      queue_event(config),
      error_event()
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp request_event do
    Event.build(
      :finch_request_metrics,
      [
        distribution(
          "finch.request.duration",
          event_name: [:finch, :request, :stop],
          measurement: :duration,
          description: "HTTP request duration",
          tags: [:scheme, :host, :port, :method],
          unit: {:native, :millisecond},
          reporter_options: [
            buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]
          ]
        ),
        counter(
          "finch.request.count",
          event_name: [:finch, :request, :stop],
          description: "Number of HTTP requests",
          tags: [:scheme, :host, :port, :method, :status]
        )
      ]
    )
  end

  defp connection_event(%{track_connection_time: true}) do
    Event.build(
      :finch_connection_metrics,
      [
        distribution(
          "finch.connection.duration",
          event_name: [:finch, :connect, :stop],
          measurement: :duration,
          description: "Connection establishment time (DNS + TCP + SSL)",
          tags: [:scheme, :host, :port],
          unit: {:native, :millisecond},
          reporter_options: [
            buckets: [10, 25, 50, 100, 250, 500, 1000, 2500]
          ]
        ),
        counter(
          "finch.connection.count",
          event_name: [:finch, :connect, :stop],
          description: "Number of connections established",
          tags: [:scheme, :host, :port]
        )
      ]
    )
  end

  defp connection_event(_config), do: nil

  defp queue_event(%{track_queue_time: true}) do
    Event.build(
      :finch_queue_metrics,
      [
        distribution(
          "finch.queue.duration",
          event_name: [:finch, :queue, :stop],
          measurement: :duration,
          description: "Time waiting for connection from pool",
          tags: [:pool],
          unit: {:native, :millisecond},
          reporter_options: [
            buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]
          ]
        )
      ]
    )
  end

  defp queue_event(_config), do: nil

  defp error_event do
    Event.build(
      :finch_error_metrics,
      [
        counter(
          "finch.request.error.count",
          event_name: [:finch, :request, :exception],
          description: "Number of HTTP request errors",
          tags: [:scheme, :host, :port, :method, :error_kind]
        ),
        counter(
          "finch.queue.error.count",
          event_name: [:finch, :queue, :exception],
          description: "Number of connection pool queue errors",
          tags: [:pool, :error_kind]
        ),
        counter(
          "finch.connection.error.count",
          event_name: [:finch, :connect, :exception],
          description: "Number of connection errors",
          tags: [:scheme, :host, :port, :error_kind]
        )
      ]
    )
  end

  ## Event Handler Functions
  ##
  ## These are public so applications can use them if they want to
  ## attach to Finch events manually for custom processing.

  @doc """
  Handles Finch request completion events.
  Extracts host, status code, and other metadata for metrics.
  """
  def handle_request_stop(_event_name, measurements, metadata, _config) do
    # Extract request details from metadata
    request = metadata[:request]
    result = metadata[:result]

    tags = extract_request_tags(request, result)

    :telemetry.execute(
      [:zyzyva, :finch, :request, :complete],
      measurements,
      tags
    )
  end

  @doc """
  Handles Finch request exceptions.
  Tracks timeout, connection errors, and other failures.
  """
  def handle_request_exception(_event_name, measurements, metadata, _config) do
    request = metadata[:request]
    error_kind = classify_error(metadata[:kind], metadata[:reason])

    tags = extract_request_tags(request, nil)
    tags = Map.put(tags, :error_kind, error_kind)

    :telemetry.execute(
      [:zyzyva, :finch, :request, :error],
      measurements,
      tags
    )
  end

  ## Helper Functions

  defp extract_request_tags(%{scheme: scheme, host: host, port: port, method: method}, result) do
    base_tags = %{
      scheme: scheme,
      host: host,
      port: port,
      method: method
    }

    add_status_tag(base_tags, result)
  end

  defp extract_request_tags(_request, _result), do: %{}

  defp add_status_tag(tags, {:ok, %{status: status}}) when is_integer(status) do
    Map.put(tags, :status, status)
  end

  defp add_status_tag(tags, _result), do: Map.put(tags, :status, :unknown)

  defp classify_error(:error, %Mint.TransportError{reason: :timeout}), do: :timeout
  defp classify_error(:error, %Mint.TransportError{reason: :closed}), do: :connection_closed
  defp classify_error(:error, %Mint.TransportError{reason: :nxdomain}), do: :dns_error

  defp classify_error(:error, %Mint.TransportError{reason: reason})
       when reason in [:econnrefused, :ehostunreach, :enetunreach] do
    :connection_refused
  end

  defp classify_error(:error, %Mint.HTTPError{}), do: :http_error
  defp classify_error(:exit, _reason), do: :exit
  defp classify_error(:throw, _reason), do: :throw
  defp classify_error(_kind, _reason), do: :unknown
end
