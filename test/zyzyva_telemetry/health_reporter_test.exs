defmodule ZyzyvaTelemetry.HealthReporterTest do
  use ExUnit.Case, async: true
  alias ZyzyvaTelemetry.HealthReporter

  @test_db_path "/tmp/test_health_monitoring_#{System.unique_integer([:positive])}.db"

  setup do
    # Initialize test database
    File.rm(@test_db_path)
    {:ok, _} = ZyzyvaTelemetry.SqliteWriter.init_database(@test_db_path)

    on_exit(fn ->
      File.rm(@test_db_path)
    end)

    {:ok, db_path: @test_db_path}
  end

  describe "start_link/1" do
    test "starts the health reporter process", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000
      }

      assert {:ok, pid} = HealthReporter.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "accepts custom health check function", %{db_path: db_path} do
      health_check_fn = fn ->
        %{
          status: :healthy,
          memory_mb: 512,
          cpu_percent: 25.5
        }
      end

      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000,
        health_check_fn: health_check_fn
      }

      assert {:ok, pid} = HealthReporter.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "report_health/2" do
    test "reports health status to database", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000
      }

      {:ok, pid} = HealthReporter.start_link(config)

      # Manually trigger health report
      health_data = %{
        status: :healthy,
        memory_mb: 256,
        cpu_percent: 15.0,
        queue_depth: 5
      }

      assert :ok = HealthReporter.report_health(pid, health_data)

      # Give it a moment to write
      Process.sleep(10)

      # Verify it was written to database
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT * FROM events WHERE event_type = 'health' ORDER BY id DESC LIMIT 1"
        )

      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) == 1
      [row] = result
      # event_type
      assert Enum.at(row, 4) == "health"

      # Check metadata was properly encoded
      metadata_json = Enum.at(row, 8)
      assert {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["status"] == "healthy"
      assert metadata["memory_mb"] == 256
      assert metadata["cpu_percent"] == 15.0
      assert metadata["queue_depth"] == 5

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)

      # Clean up
      GenServer.stop(pid)
    end

    test "reports degraded status", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000
      }

      {:ok, pid} = HealthReporter.start_link(config)

      health_data = %{
        status: :degraded,
        memory_mb: 1024,
        cpu_percent: 85.0,
        error_rate: 0.05,
        reason: "High CPU usage"
      }

      assert :ok = HealthReporter.report_health(pid, health_data)

      # Give it a moment to write
      Process.sleep(10)

      # Verify degraded status was written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT metadata FROM events WHERE event_type = 'health' ORDER BY id DESC LIMIT 1"
        )

      {:ok, [[metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["status"] == "degraded"
      assert metadata["reason"] == "High CPU usage"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)

      # Clean up
      GenServer.stop(pid)
    end

    test "reports unhealthy status", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000
      }

      {:ok, pid} = HealthReporter.start_link(config)

      health_data = %{
        status: :unhealthy,
        error: "Database connection failed",
        last_error_time: DateTime.utc_now()
      }

      assert :ok = HealthReporter.report_health(pid, health_data)

      # Give it a moment to write
      Process.sleep(10)

      # Verify unhealthy status was written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT severity, metadata FROM events WHERE event_type = 'health' ORDER BY id DESC LIMIT 1"
        )

      {:ok, [[severity, metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      # Unhealthy should be marked as error severity
      assert severity == "error"
      assert {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["status"] == "unhealthy"
      assert metadata["error"] == "Database connection failed"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "automatic periodic reporting" do
    test "reports health automatically at configured interval", %{db_path: db_path} do
      health_check_fn = fn ->
        %{
          status: :healthy,
          memory_mb: :rand.uniform(512),
          cpu_percent: :rand.uniform(100) * 1.0
        }
      end

      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        # Short interval for testing
        interval_ms: 100,
        health_check_fn: health_check_fn
      }

      {:ok, pid} = HealthReporter.start_link(config)

      # Wait for a couple of intervals
      Process.sleep(250)

      # Check that multiple health reports were written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events WHERE event_type = 'health'")

      {:ok, [[count]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      # Should have at least 2 reports (initial + periodic)
      assert count >= 2

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)

      # Clean up
      GenServer.stop(pid)
    end
  end

  describe "get_current_health/1" do
    test "returns current health status", %{db_path: db_path} do
      health_check_fn = fn ->
        %{
          status: :healthy,
          memory_mb: 256,
          custom_metric: "test"
        }
      end

      config = %{
        service_name: "test_service",
        node_id: node_id(),
        db_path: db_path,
        interval_ms: 60_000,
        health_check_fn: health_check_fn
      }

      {:ok, pid} = HealthReporter.start_link(config)

      # Get current health
      health = HealthReporter.get_current_health(pid)

      assert health.status == :healthy
      assert health.memory_mb == 256
      assert health.custom_metric == "test"

      # Clean up
      GenServer.stop(pid)
    end
  end

  # Helper to generate consistent node ID for testing
  defp node_id do
    "test_node_#{System.unique_integer([:positive])}"
  end
end
