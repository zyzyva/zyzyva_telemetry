defmodule ZyzyvaTelemetry.Plugs.PayloadTrackerTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.Plugs.PayloadTracker

  describe "call/2" do
    test "does nothing when disabled" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker, enabled: false)

      conn =
        conn(:get, "/test")
        |> PayloadTracker.call([])
        |> send_resp(200, "OK")

      assert conn.status == 200
    end

    test "tracks payload sizes when enabled" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker, enabled: true)

      # Attach telemetry handler
      capture_log(fn ->
        :telemetry.attach(
          "test-payload-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      _conn =
        conn(:post, "/api/users")
        |> put_req_header("content-length", "1234")
        |> PayloadTracker.call([])
        |> send_resp(200, "Response body")

      assert_receive {:telemetry_event, [:zyzyva, :phoenix, :payload], measurements, metadata}

      assert measurements.request_size == 1234
      assert measurements.response_size > 0
      assert metadata.method == "POST"
      assert metadata.path == "/api/users"
      assert metadata.request_type == :api
    end

    test "classifies static requests correctly" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker,
        enabled: true,
        track_static_requests: true
      )

      capture_log(fn ->
        :telemetry.attach(
          "test-static-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      _conn =
        conn(:get, "/assets/app.js")
        |> PayloadTracker.call([])
        |> send_resp(200, "console.log('test')")

      assert_receive {:telemetry_event, [:zyzyva, :phoenix, :payload], _measurements, metadata}

      assert metadata.request_type == :static
    end

    test "classifies API requests correctly" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker, enabled: true)

      capture_log(fn ->
        :telemetry.attach(
          "test-api-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      _conn =
        conn(:get, "/api/v1/users")
        |> PayloadTracker.call([])
        |> send_resp(200, "[]")

      assert_receive {:telemetry_event, [:zyzyva, :phoenix, :payload], _measurements, metadata}

      assert metadata.request_type == :api
    end

    test "classifies dynamic requests correctly" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker, enabled: true)

      capture_log(fn ->
        :telemetry.attach(
          "test-dynamic-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      _conn =
        conn(:get, "/users/123")
        |> PayloadTracker.call([])
        |> send_resp(200, "<html>User Page</html>")

      assert_receive {:telemetry_event, [:zyzyva, :phoenix, :payload], _measurements, metadata}

      assert metadata.request_type == :dynamic
    end

    test "skips static requests when configured" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker,
        enabled: true,
        track_static_requests: false
      )

      capture_log(fn ->
        :telemetry.attach(
          "test-skip-static-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      conn =
        conn(:get, "/images/logo.png")
        |> PayloadTracker.call([])
        |> send_resp(200, "PNG_DATA")

      refute_receive {:telemetry_event, _, _, _}, 100
      assert conn.status == 200
    end

    test "logs warning for large request payloads" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker,
        enabled: true,
        large_payload_threshold_kb: 1
      )

      log_output =
        capture_log(fn ->
          conn =
            conn(:post, "/api/upload")
            |> put_req_header("content-length", "2048")
            |> PayloadTracker.call([])
            |> send_resp(200, "OK")

          # Give time for before_send to execute
          _ = conn
          Process.sleep(10)
        end)

      assert log_output =~ "Large request payload detected"
      assert log_output =~ "2KB"
    end

    test "logs warning for large response payloads" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker,
        enabled: true,
        large_payload_threshold_kb: 1
      )

      large_body = String.duplicate("x", 2048)

      log_output =
        capture_log(fn ->
          conn =
            conn(:get, "/api/data")
            |> PayloadTracker.call([])
            |> send_resp(200, large_body)

          _ = conn
          Process.sleep(10)
        end)

      assert log_output =~ "Large response payload detected"
      assert log_output =~ "2KB"
    end

    test "handles missing content-length header" do
      Application.put_env(:zyzyva_telemetry, :payload_tracker, enabled: true)

      capture_log(fn ->
        :telemetry.attach(
          "test-no-header-#{System.unique_integer()}",
          [:zyzyva, :phoenix, :payload],
          fn event, measurements, metadata, _config ->
            send(self(), {:telemetry_event, event, measurements, metadata})
          end,
          nil
        )
      end)

      _conn =
        conn(:get, "/test")
        |> PayloadTracker.call([])
        |> send_resp(200, "Response")

      assert_receive {:telemetry_event, [:zyzyva, :phoenix, :payload], measurements, _metadata}

      assert measurements.request_size == 0
      assert measurements.response_size > 0
    end
  end
end
