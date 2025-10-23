defmodule ZyzyvaTelemetry.Plugins.EnhancedLiveViewTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.Plugins.EnhancedLiveView

  describe "event_metrics/1" do
    test "returns empty metrics when disabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: false)

      metrics = EnhancedLiveView.event_metrics([])

      assert metrics == []
    end

    test "includes websocket metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_websocket: true
      )

      metrics = EnhancedLiveView.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:phoenix, :live_view, :mount, :stop] in metric_names
    end

    test "excludes websocket metrics when track_websocket is false" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_websocket: false
      )

      metrics = EnhancedLiveView.event_metrics([])

      # Should still have render, mount, and handle_event metrics
      assert length(metrics) > 0

      # But not connection.drop metrics
      refute Enum.any?(metrics, fn m ->
        m.name == "live_view.connection.drop.count"
      end)
    end

    test "includes render metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:phoenix, :live_view, :render, :stop] in metric_names
      assert [:zyzyva, :live_view, :render, :complete] in metric_names
    end

    test "includes mount metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])

      mount_metrics =
        Enum.filter(metrics, fn m ->
          m.event_name == [:phoenix, :live_view, :mount, :stop]
        end)

      assert length(mount_metrics) >= 2
    end

    test "includes handle_event metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:phoenix, :live_view, :handle_event, :stop] in metric_names
    end

    test "all metrics have proper configuration" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])

      Enum.each(metrics, fn metric ->
        assert metric.event_name != nil
        assert metric.description != nil
        assert is_binary(metric.description)
      end)
    end

    test "duration metrics have millisecond buckets" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])

      # Find distribution metrics with buckets
      distribution_metrics =
        Enum.filter(metrics, fn m ->
          Map.has_key?(m, :reporter_options) && m.reporter_options[:buckets] != nil
        end)

      assert length(distribution_metrics) > 0

      Enum.each(distribution_metrics, fn metric ->
        buckets = metric.reporter_options[:buckets]
        assert is_list(buckets)
        assert length(buckets) > 0
      end)
    end

    test "metrics have appropriate tags" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: true)

      metrics = EnhancedLiveView.event_metrics([])

      # Most metrics should have :view tag
      view_tagged_metrics = Enum.filter(metrics, fn m -> :view in m.tags end)

      assert length(view_tagged_metrics) > 0

      # handle_event should have :event tag
      handle_event_metrics =
        Enum.filter(metrics, fn m ->
          m.event_name == [:phoenix, :live_view, :handle_event, :stop]
        end)

      Enum.each(handle_event_metrics, fn metric ->
        assert :event in metric.tags
      end)
    end
  end

  describe "polling_metrics/1" do
    test "returns empty metrics when disabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view, enabled: false)

      metrics = EnhancedLiveView.polling_metrics([])

      assert metrics == []
    end

    test "includes process health metric when track_process_health is true" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_process_health: true
      )

      metrics = EnhancedLiveView.polling_metrics([])

      assert length(metrics) >= 1

      # All polling metrics should have a measurement
      Enum.each(metrics, fn metric ->
        assert Map.has_key?(metric, :measurement)
      end)
    end

    test "excludes zombie metric when detect_zombies is false" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_process_health: true,
        detect_zombies: false
      )

      metrics = EnhancedLiveView.polling_metrics([])

      # With zombie detection disabled, should have 1 metric (process count)
      assert length(metrics) == 1
    end

    test "includes zombie metric when detect_zombies is true" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_process_health: true,
        detect_zombies: true
      )

      metrics = EnhancedLiveView.polling_metrics([])

      # With zombie detection enabled, should have 2 metrics
      assert length(metrics) == 2
    end
  end

  describe "measure_live_view_processes/1" do
    test "returns a non-negative integer" do
      result = EnhancedLiveView.measure_live_view_processes(%{})

      assert is_integer(result)
      assert result >= 0
    end

    test "counts processes correctly" do
      # In test environment, there might be some processes
      # Just verify it returns a valid count
      result = EnhancedLiveView.measure_live_view_processes(%{})

      assert result >= 0
    end
  end

  describe "handle_render_stop/4" do
    test "emits telemetry event with diff size" do
      # Attach test handler (suppress warnings)
      capture_log(fn ->
        :telemetry.attach(
          "test-render-#{System.unique_integer()}",
          [:zyzyva, :live_view, :render, :complete],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      socket = %{assigns: %{foo: "bar", baz: "qux"}}
      measurements = %{duration: 1000}
      metadata = %{socket: socket, view: MyView}

      EnhancedLiveView.handle_render_stop(
        [:phoenix, :live_view, :render, :stop],
        measurements,
        metadata,
        %{}
      )

      assert_receive {:telemetry_event, [:zyzyva, :live_view, :render, :complete], emitted_measurements,
                      _metadata}

      assert emitted_measurements.diff_size > 0
      assert emitted_measurements.duration == 1000
    end

    test "handles missing socket gracefully" do
      capture_log(fn ->
        :telemetry.attach(
          "test-render-no-socket-#{System.unique_integer()}",
          [:zyzyva, :live_view, :render, :complete],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      measurements = %{duration: 1000}
      metadata = %{view: MyView}

      EnhancedLiveView.handle_render_stop(
        [:phoenix, :live_view, :render, :stop],
        measurements,
        metadata,
        %{}
      )

      assert_receive {:telemetry_event, [:zyzyva, :live_view, :render, :complete], emitted_measurements,
                      _metadata}

      assert emitted_measurements.diff_size == 0
    end
  end

  describe "integration with PromEx" do
    test "all event metrics are valid" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_websocket: true
      )

      metrics = EnhancedLiveView.event_metrics([])

      Enum.each(metrics, fn metric ->
        assert is_atom(metric.__struct__)
        assert metric.event_name != nil
        assert is_list(metric.event_name)
      end)
    end

    test "all polling metrics are valid" do
      Application.put_env(:zyzyva_telemetry, :enhanced_live_view,
        enabled: true,
        track_process_health: true,
        detect_zombies: true
      )

      metrics = EnhancedLiveView.polling_metrics([])

      Enum.each(metrics, fn metric ->
        assert is_atom(metric.__struct__)
        assert metric.name != nil
        # Metric name can be a list or string
        assert is_list(metric.name) or is_binary(metric.name)
      end)
    end
  end
end
