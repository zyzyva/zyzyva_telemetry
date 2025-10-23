# Simple benchmark for telemetry overhead
# Run with: mix run benchmark.exs

defmodule TelemetryBenchmark do
  def run do
    IO.puts("\n=== Telemetry Overhead Benchmark ===\n")

    # Warm up
    Enum.each(1..1000, fn _ -> :telemetry.execute([:test], %{value: 1}, %{}) end)

    # Benchmark 1: Raw telemetry event emission (no handlers)
    {time_no_handlers, _} = :timer.tc(fn ->
      Enum.each(1..100_000, fn _ ->
        :telemetry.execute([:benchmark, :test], %{value: 1}, %{})
      end)
    end)

    # Benchmark 2: With a simple handler attached
    :telemetry.attach(
      "bench-handler",
      [:benchmark, :test, :with_handler],
      fn _event, _measurements, _metadata, _config -> :ok end,
      nil
    )

    {time_with_handler, _} = :timer.tc(fn ->
      Enum.each(1..100_000, fn _ ->
        :telemetry.execute([:benchmark, :test, :with_handler], %{value: 1}, %{})
      end)
    end)

    # Benchmark 3: With typical contacts4us telemetry (user hash + correlation ID)
    :telemetry.attach(
      "bench-contacts4us",
      [:benchmark, :test, :contacts4us],
      fn _event, _measurements, metadata, _config ->
        # Simulate what TelemetryHelper.emit does
        user_id = metadata[:user_id]
        _user_hash = if user_id, do: :crypto.hash(:sha256, "#{user_id}") |> Base.encode16() |> String.slice(0..15), else: nil
        :ok
      end,
      nil
    )

    {time_contacts4us, _} = :timer.tc(fn ->
      Enum.each(1..100_000, fn _ ->
        :telemetry.execute(
          [:benchmark, :test, :contacts4us],
          %{count: 1},
          %{user_id: 123, correlation_id: "abc123"}
        )
      end)
    end)

    # Calculate overhead
    us_per_event_no_handler = time_no_handlers / 100_000
    us_per_event_with_handler = time_with_handler / 100_000
    us_per_event_contacts4us = time_contacts4us / 100_000

    IO.puts("Results (100,000 events):")
    IO.puts("  No handlers:           #{format_time(time_no_handlers)} (#{Float.round(us_per_event_no_handler, 3)} μs/event)")
    IO.puts("  With simple handler:   #{format_time(time_with_handler)} (#{Float.round(us_per_event_with_handler, 3)} μs/event)")
    IO.puts("  With user hash (C4US): #{format_time(time_contacts4us)} (#{Float.round(us_per_event_contacts4us, 3)} μs/event)")

    IO.puts("\nOverhead per event:")
    IO.puts("  Simple handler:     #{Float.round(us_per_event_with_handler - us_per_event_no_handler, 3)} μs")
    IO.puts("  User hash (C4US):   #{Float.round(us_per_event_contacts4us - us_per_event_no_handler, 3)} μs")

    IO.puts("\nProjected impact at 1000 req/sec (10 telemetry events/req):")
    requests_per_sec = 1000
    events_per_request = 10  # Typical: 1 query, 1 render, 1 mount, etc.

    # Enhanced monitoring plugins overhead (simple handlers)
    monitoring_overhead_ms = (us_per_event_with_handler * events_per_request * requests_per_sec) / 1000
    IO.puts("  Enhanced monitoring: ~#{Float.round(monitoring_overhead_ms, 2)} ms/sec (~#{Float.round(monitoring_overhead_ms / 10, 2)}%)")

    # Business telemetry overhead (with user hashing)
    business_events_per_request = 2  # Typical: create, update operations
    business_overhead_ms = (us_per_event_contacts4us * business_events_per_request * requests_per_sec) / 1000
    IO.puts("  Business telemetry:  ~#{Float.round(business_overhead_ms, 2)} ms/sec (~#{Float.round(business_overhead_ms / 10, 2)}%)")

    total_overhead_ms = monitoring_overhead_ms + business_overhead_ms
    IO.puts("  TOTAL overhead:      ~#{Float.round(total_overhead_ms, 2)} ms/sec (~#{Float.round(total_overhead_ms / 10, 2)}%)")

    # Cleanup
    :telemetry.detach("bench-handler")
    :telemetry.detach("bench-contacts4us")

    IO.puts("\n")
  end

  defp format_time(microseconds) do
    cond do
      microseconds > 1_000_000 -> "#{Float.round(microseconds / 1_000_000, 2)} s"
      microseconds > 1_000 -> "#{Float.round(microseconds / 1_000, 2)} ms"
      true -> "#{Float.round(microseconds, 2)} μs"
    end
  end
end

TelemetryBenchmark.run()
