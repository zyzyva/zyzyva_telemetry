defmodule ZyzyvaTelemetry.Plugins.EnhancedPhoenixTest do
  use ExUnit.Case, async: true

  alias ZyzyvaTelemetry.Plugins.EnhancedPhoenix

  describe "event_metrics/1" do
    test "returns empty metrics when disabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix, enabled: false)

      metrics = EnhancedPhoenix.event_metrics([])

      assert metrics == []
    end

    test "includes payload metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:zyzyva, :phoenix, :payload] in metric_names
    end

    test "includes request type metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix, enabled: true)

      metrics = EnhancedPhoenix.event_metrics([])

      # Should have request type count and duration
      payload_metrics =
        Enum.filter(metrics, fn m -> m.event_name == [:zyzyva, :phoenix, :payload] end)

      assert length(payload_metrics) > 0
    end

    test "excludes payload size metrics when track_payload_sizes is false" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: false
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # Should still have request type metrics but not payload size metrics
      assert length(metrics) == 2

      # All metrics should be for request type tracking
      Enum.each(metrics, fn metric ->
        assert metric.event_name == [:zyzyva, :phoenix, :payload]
      end)
    end

    test "all payload metrics have proper configuration" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      Enum.each(metrics, fn metric ->
        assert metric.event_name == [:zyzyva, :phoenix, :payload]
        assert metric.description != nil
        assert is_binary(metric.description)
      end)
    end

    test "payload size metrics have byte buckets" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # Find distribution metrics (which have reporter_options)
      distribution_metrics =
        Enum.filter(metrics, fn m ->
          Map.has_key?(m, :reporter_options) && m.unit == :byte
        end)

      assert length(distribution_metrics) > 0

      # Check first distribution has proper buckets
      first_metric = List.first(distribution_metrics)
      buckets = first_metric.reporter_options[:buckets]
      assert is_list(buckets)
      assert length(buckets) > 0
      # Should include buckets for various sizes (bytes to MB)
      assert 100 in buckets
      assert 1_000_000 in buckets
    end

    test "request type duration metric exists" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # When track_payload_sizes is true, we should have:
      # - 2 distributions (request_size, response_size)
      # - 1 summary (total_size)
      # - 1 counter (request_type.count)
      # - 1 distribution (request_type.duration)
      # Total: 5 metrics
      assert length(metrics) == 5

      # All metrics should have request_type tag
      Enum.each(metrics, fn metric ->
        assert :request_type in metric.tags
      end)
    end

    test "metrics have appropriate tags" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # All metrics should have request_type tag
      Enum.each(metrics, fn metric ->
        assert :request_type in metric.tags
      end)

      # Find byte-sized metrics (request/response size)
      byte_metrics = Enum.filter(metrics, fn m -> m.unit == :byte end)

      assert length(byte_metrics) >= 2

      # Check that byte metrics have method and route tags
      Enum.each(byte_metrics, fn metric ->
        assert :method in metric.tags
        assert :route in metric.tags
        assert :request_type in metric.tags
      end)
    end

    test "includes total payload size summary metric" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # Find summary metrics (they have a measurement function)
      summary_metrics =
        Enum.filter(metrics, fn m ->
          Map.has_key?(m, :measurement) && is_function(m.measurement)
        end)

      assert length(summary_metrics) > 0

      first_summary = List.first(summary_metrics)
      assert first_summary.unit == :byte
    end

    test "total_size metric calculates sum of request and response" do
      Application.put_env(:zyzyva_telemetry, :enhanced_phoenix,
        enabled: true,
        track_payload_sizes: true
      )

      metrics = EnhancedPhoenix.event_metrics([])

      # Find summary metric with a measurement function
      summary_metric =
        Enum.find(metrics, fn m ->
          Map.has_key?(m, :measurement) && is_function(m.measurement)
        end)

      assert summary_metric != nil

      # Test the measurement function
      measurements = %{request_size: 1000, response_size: 2000}
      result = summary_metric.measurement.(measurements)

      assert result == 3000
    end
  end
end
