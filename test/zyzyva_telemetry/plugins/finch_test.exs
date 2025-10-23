defmodule ZyzyvaTelemetry.Plugins.FinchTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.Plugins.Finch

  describe "event_metrics/1" do
    test "returns empty metrics when disabled" do
      Application.put_env(:zyzyva_telemetry, :finch, enabled: false)

      metrics = Finch.event_metrics([])

      assert metrics == []
    end

    test "includes request metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :finch, enabled: true)

      metrics = Finch.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:finch, :request, :stop] in metric_names
    end

    test "includes connection metrics when track_connection_time enabled" do
      Application.put_env(:zyzyva_telemetry, :finch,
        enabled: true,
        track_connection_time: true
      )

      metrics = Finch.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:finch, :connect, :stop] in metric_names
    end

    test "excludes connection metrics when track_connection_time disabled" do
      Application.put_env(:zyzyva_telemetry, :finch,
        enabled: true,
        track_connection_time: false
      )

      metrics = Finch.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      refute [:finch, :connect, :stop] in metric_names
    end

    test "includes queue metrics when track_queue_time enabled" do
      Application.put_env(:zyzyva_telemetry, :finch,
        enabled: true,
        track_queue_time: true
      )

      metrics = Finch.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:finch, :queue, :stop] in metric_names
    end

    test "includes error metrics when enabled" do
      Application.put_env(:zyzyva_telemetry, :finch, enabled: true)

      metrics = Finch.event_metrics([])
      metric_names = Enum.map(metrics, & &1.event_name)

      assert [:finch, :request, :exception] in metric_names
      assert [:finch, :queue, :exception] in metric_names
      assert [:finch, :connect, :exception] in metric_names
    end
  end

  describe "handle_request_stop/4" do
    setup do
      # Attach test handler to capture emitted events
      capture_log(fn ->
        :telemetry.attach(
          "test-finch-request-#{System.unique_integer()}",
          [:zyzyva, :finch, :request, :complete],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      on_exit(fn ->
        :telemetry.list_handlers([])
        |> Enum.filter(fn handler ->
          case handler.id do
            id when is_binary(id) -> String.starts_with?(id, "test-finch-request")
            _ -> false
          end
        end)
        |> Enum.each(&:telemetry.detach(&1.id))
      end)

      :ok
    end

    test "extracts request metadata with successful response" do
      request = %{
        scheme: :https,
        host: "api.example.com",
        port: 443,
        method: "GET"
      }

      result = {:ok, %{status: 200}}

      measurements = %{duration: 100_000}
      metadata = %{request: request, result: result}

      Finch.handle_request_stop([:finch, :request, :stop], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :complete], ^measurements,
                      tags}

      assert tags.scheme == :https
      assert tags.host == "api.example.com"
      assert tags.port == 443
      assert tags.method == "GET"
      assert tags.status == 200
    end

    test "handles request without status code" do
      request = %{
        scheme: :https,
        host: "api.example.com",
        port: 443,
        method: "POST"
      }

      measurements = %{duration: 50_000}
      metadata = %{request: request, result: nil}

      Finch.handle_request_stop([:finch, :request, :stop], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :complete], ^measurements,
                      tags}

      assert tags.status == :unknown
    end
  end

  describe "handle_request_exception/4" do
    setup do
      capture_log(fn ->
        :telemetry.attach(
          "test-finch-error-#{System.unique_integer()}",
          [:zyzyva, :finch, :request, :error],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      on_exit(fn ->
        :telemetry.list_handlers([])
        |> Enum.filter(fn handler ->
          case handler.id do
            id when is_binary(id) -> String.starts_with?(id, "test-finch-error")
            _ -> false
          end
        end)
        |> Enum.each(&:telemetry.detach(&1.id))
      end)

      :ok
    end

    test "classifies timeout errors" do
      request = %{
        scheme: :https,
        host: "slow.example.com",
        port: 443,
        method: "GET"
      }

      measurements = %{duration: 30_000_000}
      error = %Mint.TransportError{reason: :timeout}

      metadata = %{
        request: request,
        kind: :error,
        reason: error,
        stacktrace: []
      }

      Finch.handle_request_exception([:finch, :request, :exception], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :error], ^measurements, tags}

      assert tags.error_kind == :timeout
      assert tags.host == "slow.example.com"
    end

    test "classifies connection refused errors" do
      request = %{
        scheme: :http,
        host: "unreachable.example.com",
        port: 80,
        method: "GET"
      }

      measurements = %{duration: 1000}
      error = %Mint.TransportError{reason: :econnrefused}

      metadata = %{
        request: request,
        kind: :error,
        reason: error,
        stacktrace: []
      }

      Finch.handle_request_exception([:finch, :request, :exception], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :error], ^measurements, tags}

      assert tags.error_kind == :connection_refused
    end

    test "classifies DNS errors" do
      request = %{
        scheme: :https,
        host: "nonexistent.invalid",
        port: 443,
        method: "GET"
      }

      measurements = %{duration: 5000}
      error = %Mint.TransportError{reason: :nxdomain}

      metadata = %{
        request: request,
        kind: :error,
        reason: error,
        stacktrace: []
      }

      Finch.handle_request_exception([:finch, :request, :exception], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :error], ^measurements, tags}

      assert tags.error_kind == :dns_error
    end

    test "classifies HTTP errors" do
      request = %{
        scheme: :https,
        host: "api.example.com",
        port: 443,
        method: "GET"
      }

      measurements = %{duration: 1000}
      error = %Mint.HTTPError{reason: :invalid_status_line, module: Mint.HTTP1}

      metadata = %{
        request: request,
        kind: :error,
        reason: error,
        stacktrace: []
      }

      Finch.handle_request_exception([:finch, :request, :exception], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :error], ^measurements, tags}

      assert tags.error_kind == :http_error
    end

    test "classifies unknown errors" do
      request = %{
        scheme: :https,
        host: "api.example.com",
        port: 443,
        method: "GET"
      }

      measurements = %{duration: 1000}

      metadata = %{
        request: request,
        kind: :error,
        reason: :some_unexpected_error,
        stacktrace: []
      }

      Finch.handle_request_exception([:finch, :request, :exception], measurements, metadata, %{})

      assert_receive {:telemetry_event, [:zyzyva, :finch, :request, :error], ^measurements, tags}

      assert tags.error_kind == :unknown
    end
  end

  describe "integration with PromEx metrics" do
    test "all metrics have required fields" do
      Application.put_env(:zyzyva_telemetry, :finch, enabled: true)

      metrics = Finch.event_metrics([])

      Enum.each(metrics, fn metric ->
        assert metric.event_name != nil
        assert metric.description != nil
        assert is_atom(metric.__struct__)
      end)
    end

    test "request duration metric uses correct buckets" do
      Application.put_env(:zyzyva_telemetry, :finch, enabled: true)

      metrics = Finch.event_metrics([])

      duration_metric =
        Enum.find(metrics, fn m ->
          m.event_name == [:finch, :request, :stop] &&
            Map.has_key?(m, :reporter_options)
        end)

      assert duration_metric != nil
      assert duration_metric.reporter_options[:buckets] != nil
      assert length(duration_metric.reporter_options[:buckets]) > 0
    end
  end
end
