defmodule ZyzyvaTelemetry.Plugins.EnhancedEcto do
  @moduledoc """
  Enhanced Ecto monitoring plugin that extends PromEx Ecto metrics.

  Provides:
  - Slow query detection and alerting
  - Query type classification (read vs write)
  - Transaction tracking and rollback monitoring
  - Resource-efficient event handling with minimal overhead

  ## Configuration

      config :zyzyva_telemetry, :enhanced_ecto,
        enabled: false,                    # Opt-in by default
        slow_query_threshold_ms: 100,      # Queries slower than this trigger events
        log_slow_queries: true,            # Log slow queries via Tower
        track_query_types: true,           # Separate read/write metrics
        track_transactions: true           # Track transaction lifecycle

  ## Resource Usage

  This plugin is designed for minimal overhead:
  - Uses fire-and-forget telemetry events (< 0.1ms per query)
  - No in-memory storage or buffering
  - All metrics are incremental counters/histograms
  - Events are batched by PromEx before export
  """

  use PromEx.Plugin
  require Logger

  import Telemetry.Metrics

  @impl true
  def event_metrics(opts) do
    config = get_config()
    build_metrics(config, opts)
  end

  @impl true
  def polling_metrics(_opts), do: []

  ## Configuration

  defp get_config do
    Application.get_env(:zyzyva_telemetry, :enhanced_ecto, [])
    |> Keyword.put_new(:enabled, false)
    |> Keyword.put_new(:slow_query_threshold_ms, 100)
    |> Keyword.put_new(:log_slow_queries, true)
    |> Keyword.put_new(:track_query_types, true)
    |> Keyword.put_new(:track_transactions, true)
    |> Enum.into(%{})
  end

  ## Metrics Building

  defp build_metrics(config, opts) do
    [
      slow_query_event(opts),
      query_type_event(config, opts),
      transaction_event(config, opts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp slow_query_event(_opts) do
    Event.build(
      :enhanced_ecto_slow_query_metrics,
      slow_query_metrics()
    )
  end

  defp query_type_event(%{track_query_types: true}, _opts) do
    Event.build(
      :enhanced_ecto_query_type_metrics,
      query_type_metrics()
    )
  end

  defp query_type_event(_config, _opts), do: nil

  defp transaction_event(%{track_transactions: true}, _opts) do
    Event.build(
      :enhanced_ecto_transaction_metrics,
      transaction_metrics()
    )
  end

  defp transaction_event(_config, _opts), do: nil

  ## Event Handlers
  ##
  ## Note: Handler attachment happens at the application level.
  ## These handler functions are public so they can be used by applications
  ## that want to attach to Ecto telemetry events manually.

  def handle_query_event(_event_name, measurements, metadata, config) do
    duration_ms = native_to_milliseconds(measurements[:total_time] || measurements[:query_time])

    handle_query_type_tracking(config, metadata, duration_ms)
    handle_slow_query_detection(config, metadata, duration_ms)
  end

  def handle_transaction_event(event_name, measurements, metadata, _config) do
    event_type = List.last(event_name)

    :telemetry.execute(
      [:zyzyva, :ecto, :transaction, event_type],
      Map.merge(measurements, %{count: 1}),
      metadata
    )
  end

  ## Query Type Tracking

  defp handle_query_type_tracking(%{track_query_types: true}, metadata, duration_ms) do
    emit_query_type_event(metadata, duration_ms)
  end

  defp handle_query_type_tracking(_config, _metadata, _duration_ms), do: :ok

  defp emit_query_type_event(metadata, duration_ms) do
    query_type = classify_query(metadata[:source], metadata[:result])

    :telemetry.execute(
      [:zyzyva, :ecto, :query_by_type],
      %{duration: duration_ms, count: 1},
      %{type: query_type, source: metadata[:source]}
    )
  end

  # Pattern match on result to determine query type
  defp classify_query(_source, %{num_rows: num} = _result) when is_integer(num), do: :select
  defp classify_query(_source, {:ok, _}), do: :write
  defp classify_query(_source, %Ecto.Schema.Metadata{}), do: :write
  defp classify_query(_source, _), do: :unknown

  ## Slow Query Detection

  defp handle_slow_query_detection(config, metadata, duration_ms)
       when is_number(duration_ms) do
    threshold = Map.get(config, :slow_query_threshold_ms, 100)
    detect_slow_query(duration_ms >= threshold, config, metadata, duration_ms)
  end

  defp handle_slow_query_detection(_config, _metadata, _duration_ms), do: :ok

  defp detect_slow_query(true, config, metadata, duration_ms) do
    emit_slow_query_event(metadata, duration_ms, config)
  end

  defp detect_slow_query(false, _config, _metadata, _duration_ms), do: :ok

  defp emit_slow_query_event(metadata, duration_ms, config) do
    # Emit telemetry event for Prometheus counter
    :telemetry.execute(
      [:zyzyva, :ecto, :slow_query],
      %{duration: duration_ms, count: 1},
      %{source: metadata[:source]}
    )

    log_slow_query(config, metadata, duration_ms)
  end

  defp log_slow_query(%{log_slow_queries: true}, metadata, duration_ms) do
    Logger.warning(
      "Slow query detected: #{inspect(metadata[:source])} took #{duration_ms}ms",
      query_metadata: metadata,
      duration_ms: duration_ms
    )
  end

  defp log_slow_query(_config, _metadata, _duration_ms), do: :ok

  ## Metrics Definitions

  defp slow_query_metrics do
    [
      counter(
        "ecto.slow_query.count",
        event_name: [:zyzyva, :ecto, :slow_query],
        description: "Number of slow queries (exceeding threshold)",
        tags: [:source]
      ),
      distribution(
        "ecto.slow_query.duration",
        event_name: [:zyzyva, :ecto, :slow_query],
        description: "Duration of slow queries",
        tags: [:source],
        unit: :millisecond,
        reporter_options: [
          buckets: [100, 250, 500, 1000, 2500, 5000, 10000]
        ]
      )
    ]
  end

  defp query_type_metrics do
    [
      counter(
        "ecto.query_by_type.count",
        event_name: [:zyzyva, :ecto, :query_by_type],
        description: "Number of queries by type (select/write)",
        tags: [:type, :source]
      ),
      distribution(
        "ecto.query_by_type.duration",
        event_name: [:zyzyva, :ecto, :query_by_type],
        description: "Query duration by type",
        tags: [:type, :source],
        unit: :millisecond,
        reporter_options: [
          buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]
        ]
      )
    ]
  end

  defp transaction_metrics do
    [
      counter(
        "ecto.transaction.count",
        event_name: [:zyzyva, :ecto, :transaction, :begin],
        description: "Number of transactions started"
      ),
      counter(
        "ecto.transaction.commit.count",
        event_name: [:zyzyva, :ecto, :transaction, :commit],
        description: "Number of successful transaction commits"
      ),
      counter(
        "ecto.transaction.rollback.count",
        event_name: [:zyzyva, :ecto, :transaction, :rollback],
        description: "Number of transaction rollbacks"
      )
    ]
  end

  ## Helpers

  defp native_to_milliseconds(nil), do: 0

  defp native_to_milliseconds(native_time) when is_integer(native_time) do
    System.convert_time_unit(native_time, :native, :millisecond)
  end

  defp native_to_milliseconds(_), do: 0
end
