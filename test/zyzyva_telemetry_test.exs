defmodule ZyzyvaTelemetryTest do
  use ExUnit.Case
  doctest ZyzyvaTelemetry

  @test_db_path "/tmp/test_telemetry_main_#{System.unique_integer([:positive])}.db"

  setup do
    File.rm(@test_db_path)

    on_exit(fn ->
      File.rm(@test_db_path)
      # Clean up any running processes
      case Process.whereis(:zyzyva_telemetry_health_reporter) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      ZyzyvaTelemetry.ErrorLogger.clear_configuration()
    end)

    {:ok, db_path: @test_db_path}
  end

  describe "MonitoringSupervisor" do
    test "initializes telemetry system with required options", %{db_path: db_path} do
      config = [
        service_name: "test_service",
        db_path: db_path,
        enable_database: true
      ]

      assert {:ok, _pid} = ZyzyvaTelemetry.MonitoringSupervisor.start_link(config)

      # Check that error logger is configured
      assert :ok = ZyzyvaTelemetry.log_error("Test error")

      Process.sleep(10)

      # Check that health reporter is running
      assert pid = Process.whereis(:zyzyva_telemetry_health_reporter)
      assert Process.alive?(pid)
    end

    test "uses default db path if not specified" do
      config = [
        service_name: "test_service",
        enable_database: true
      ]

      assert {:ok, pid} = ZyzyvaTelemetry.MonitoringSupervisor.start_link(config)

      # Should have created the default directory
      assert File.exists?("/var/lib/monitoring") or File.exists?("/tmp/monitoring_test")

      # Clean up
      GenServer.stop(pid)
    end

    test "allows custom health check function", %{db_path: db_path} do
      health_check = fn ->
        %{
          status: :healthy,
          custom_metric: "value"
        }
      end

      config = [
        service_name: "test_service",
        db_path: db_path,
        extra_health_checks: %{custom: health_check},
        enable_database: true
      ]

      assert {:ok, _pid} = ZyzyvaTelemetry.MonitoringSupervisor.start_link(config)

      Process.sleep(100)

      # Check that custom health check is being used
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT metadata FROM events WHERE event_type = 'health' LIMIT 1"
        )

      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) > 0
      [[metadata_json]] = result
      {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["custom_metric"] == "value"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "logging functions" do
    setup %{db_path: db_path} do
      config = [
        service_name: "test_service",
        db_path: db_path,
        enable_database: true
      ]

      {:ok, _pid} = ZyzyvaTelemetry.MonitoringSupervisor.start_link(config)
      {:ok, db_path: db_path}
    end

    test "log_error/1 logs an error", %{db_path: db_path} do
      assert :ok = ZyzyvaTelemetry.log_error("Something went wrong")

      Process.sleep(10)

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT message FROM events WHERE event_type = 'error'")

      {:ok, [[message]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert message == "Something went wrong"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "log_error/2 logs an error with metadata", %{db_path: db_path} do
      metadata = %{user_id: 123, action: "create_post"}
      assert :ok = ZyzyvaTelemetry.log_error("Failed to create post", metadata)

      Process.sleep(10)

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT metadata FROM events WHERE event_type = 'error'")

      {:ok, [[metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      {:ok, decoded} = JSON.decode(metadata_json)
      assert decoded["user_id"] == 123
      assert decoded["action"] == "create_post"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "log_warning/1 logs a warning", %{db_path: db_path} do
      assert :ok = ZyzyvaTelemetry.log_warning("Memory usage high")

      Process.sleep(10)

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT severity FROM events WHERE message = 'Memory usage high'"
        )

      {:ok, [[severity]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert severity == "warning"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "with_correlation/2 sets correlation for block", %{db_path: db_path} do
      result =
        ZyzyvaTelemetry.with_correlation("test-correlation-123", fn ->
          ZyzyvaTelemetry.log_error("Error within correlation")
          :ok
        end)

      assert result == :ok

      Process.sleep(10)

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT correlation_id FROM events WHERE message = 'Error within correlation'"
        )

      {:ok, [[correlation_id]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert correlation_id == "test-correlation-123"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "health reporting" do
    test "report_health/1 manually reports health", %{db_path: db_path} do
      config = [
        service_name: "test_service",
        db_path: db_path,
        enable_database: true
      ]

      {:ok, _pid} = ZyzyvaTelemetry.MonitoringSupervisor.start_link(config)

      health_data = %{
        status: :degraded,
        reason: "Queue backup"
      }

      assert :ok = ZyzyvaTelemetry.report_health(health_data)

      Process.sleep(10)

      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT metadata FROM events WHERE event_type = 'health' ORDER BY id DESC LIMIT 1"
        )

      {:ok, [[metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["status"] == "degraded"
      assert metadata["reason"] == "Queue backup"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "correlation" do
    test "get_correlation/0 returns current correlation ID" do
      ZyzyvaTelemetry.set_correlation("test-123")
      assert ZyzyvaTelemetry.get_correlation() == "test-123"
    end

    test "new_correlation/0 generates and sets new correlation ID" do
      id = ZyzyvaTelemetry.new_correlation()
      assert is_binary(id)
      assert ZyzyvaTelemetry.get_correlation() == id
    end
  end
end
