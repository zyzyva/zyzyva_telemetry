defmodule ZyzyvaTelemetry.Plugins.EnhancedEctoTest do
  use ExUnit.Case
  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.Plugins.EnhancedEcto

  describe "event_metrics/1" do
    test "returns empty metrics when all tracking disabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_ecto,
        track_query_types: false,
        track_transactions: false
      )

      metrics = EnhancedEcto.event_metrics([])
      # Should only have slow query metrics (always included)
      assert length(metrics) == 2
    end

    test "includes query type metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_ecto, track_query_types: true)

      metrics = EnhancedEcto.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)
      assert [:zyzyva, :ecto, :query_by_type] in metric_names
    end

    test "includes transaction metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_ecto, track_transactions: true)

      metrics = EnhancedEcto.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)
      assert [:zyzyva, :ecto, :transaction, :begin] in metric_names
      assert [:zyzyva, :ecto, :transaction, :commit] in metric_names
      assert [:zyzyva, :ecto, :transaction, :rollback] in metric_names
    end
  end

  describe "handle_query_event/4" do
    setup do
      # Attach test handler to capture emitted events (suppress telemetry warnings)
      capture_log(fn ->
        :telemetry.attach_many(
          "test-enhanced-ecto-#{System.unique_integer()}",
          [
            [:zyzyva, :ecto, :query_by_type],
            [:zyzyva, :ecto, :slow_query]
          ],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      on_exit(fn ->
        # Clean up handlers - match on string IDs that start with our test prefix
        :telemetry.list_handlers([])
        |> Enum.filter(fn handler ->
          case handler.id do
            id when is_binary(id) -> String.starts_with?(id, "test-enhanced-ecto")
            _ -> false
          end
        end)
        |> Enum.each(&:telemetry.detach(&1.id))
      end)

      :ok
    end

    test "emits query type event when tracking enabled" do
      config = %{
        track_query_types: true,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: false
      }

      metadata = %{source: "users", result: %{num_rows: 5}}
      measurements = %{query_time: milliseconds_to_native(50)}

      EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :query_by_type], %{duration: 50},
                      %{type: :select, source: "users"}}
    end

    test "emits slow query event when threshold exceeded" do
      config = %{
        track_query_types: false,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: false
      }

      metadata = %{source: "users"}
      measurements = %{query_time: milliseconds_to_native(150)}

      EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :slow_query], %{duration: 150},
                      %{source: "users"}}
    end

    test "does not emit slow query event when below threshold" do
      config = %{
        track_query_types: false,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: false
      }

      metadata = %{source: "users"}
      measurements = %{query_time: milliseconds_to_native(50)}

      EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)

      refute_receive {:telemetry_event, [:zyzyva, :ecto, :slow_query], _, _}, 100
    end

    test "logs slow query when log_slow_queries enabled" do
      config = %{
        track_query_types: false,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: true
      }

      metadata = %{source: "users"}
      measurements = %{query_time: milliseconds_to_native(200)}

      log_output =
        capture_log(fn ->
          EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)
          Process.sleep(10)
        end)

      assert log_output =~ "Slow query detected"
      assert log_output =~ "took 200ms"
    end

    test "classifies SELECT queries correctly" do
      config = %{
        track_query_types: true,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: false
      }

      metadata = %{source: "users", result: %{num_rows: 10}}
      measurements = %{query_time: milliseconds_to_native(10)}

      EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :query_by_type], _,
                      %{type: :select, source: "users"}}
    end

    test "classifies WRITE queries correctly" do
      config = %{
        track_query_types: true,
        track_transactions: false,
        slow_query_threshold_ms: 100,
        log_slow_queries: false
      }

      metadata = %{source: "users", result: {:ok, %{id: 1}}}
      measurements = %{query_time: milliseconds_to_native(10)}

      EnhancedEcto.handle_query_event([:test, :query], measurements, metadata, config)

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :query_by_type], _,
                      %{type: :write, source: "users"}}
    end
  end

  describe "handle_transaction_event/4" do
    setup do
      # Attach test handler (suppress telemetry warnings)
      capture_log(fn ->
        :telemetry.attach_many(
          "test-transaction-#{System.unique_integer()}",
          [
            [:zyzyva, :ecto, :transaction, :begin],
            [:zyzyva, :ecto, :transaction, :commit],
            [:zyzyva, :ecto, :transaction, :rollback]
          ],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      on_exit(fn ->
        # Clean up handlers - match on string IDs that start with our test prefix
        :telemetry.list_handlers([])
        |> Enum.filter(fn handler ->
          case handler.id do
            id when is_binary(id) -> String.starts_with?(id, "test-transaction")
            _ -> false
          end
        end)
        |> Enum.each(&:telemetry.detach(&1.id))
      end)

      :ok
    end

    test "emits begin event" do
      EnhancedEcto.handle_transaction_event(
        [:test, :transaction, :begin],
        %{},
        %{repo: TestRepo},
        %{}
      )

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :transaction, :begin], %{count: 1}, _}
    end

    test "emits commit event" do
      EnhancedEcto.handle_transaction_event(
        [:test, :transaction, :commit],
        %{},
        %{repo: TestRepo},
        %{}
      )

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :transaction, :commit], %{count: 1}, _}
    end

    test "emits rollback event" do
      EnhancedEcto.handle_transaction_event(
        [:test, :transaction, :rollback],
        %{},
        %{repo: TestRepo},
        %{}
      )

      assert_receive {:telemetry_event, [:zyzyva, :ecto, :transaction, :rollback], %{count: 1},
                      _}
    end
  end

  # Helper functions

  defp milliseconds_to_native(ms) do
    System.convert_time_unit(ms, :millisecond, :native)
  end
end
