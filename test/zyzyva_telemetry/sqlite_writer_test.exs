defmodule ZyzyvaTelemetry.SqliteWriterTest do
  use ExUnit.Case, async: true
  alias ZyzyvaTelemetry.SqliteWriter

  @test_db_path "/tmp/test_monitoring_#{System.unique_integer([:positive])}.db"

  setup do
    # Clean up any existing test database
    File.rm(@test_db_path)

    on_exit(fn ->
      File.rm(@test_db_path)
    end)

    {:ok, db_path: @test_db_path}
  end

  describe "init_database/1" do
    test "creates database file and tables", %{db_path: db_path} do
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)
      assert File.exists?(db_path)
    end

    test "creates events table with correct schema", %{db_path: db_path} do
      {:ok, _} = SqliteWriter.init_database(db_path)

      # Verify table exists and has correct columns
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT sql FROM sqlite_master WHERE name='events'")

      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) > 0
      [[create_sql]] = result
      assert create_sql =~ "timestamp"
      assert create_sql =~ "service_name"
      assert create_sql =~ "node_id"
      assert create_sql =~ "event_type"
      assert create_sql =~ "severity"
      assert create_sql =~ "message"
      assert create_sql =~ "correlation_id"
      assert create_sql =~ "metadata"
      assert create_sql =~ "forwarded"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "is idempotent - can be called multiple times", %{db_path: db_path} do
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)
    end
  end

  describe "write_event/2" do
    setup %{db_path: db_path} do
      {:ok, _} = SqliteWriter.init_database(db_path)
      {:ok, db_path: db_path}
    end

    test "writes error event to database", %{db_path: db_path} do
      event = %{
        service_name: "test_service",
        node_id: "node1",
        event_type: "error",
        severity: "error",
        message: "Something went wrong",
        correlation_id: "abc123",
        metadata: %{
          error_type: "RuntimeError",
          stack_trace: ["line1", "line2"]
        }
      }

      assert :ok = SqliteWriter.write_event(db_path, event)

      # Verify event was written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT * FROM events WHERE correlation_id = ?")

      :ok = Exqlite.Sqlite3.bind(statement, ["abc123"])
      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) == 1
      [row] = result
      # service_name
      assert Enum.at(row, 2) == "test_service"
      # node_id
      assert Enum.at(row, 3) == "node1"
      # event_type
      assert Enum.at(row, 4) == "error"
      # severity
      assert Enum.at(row, 5) == "error"
      # message
      assert Enum.at(row, 6) == "Something went wrong"
      # correlation_id
      assert Enum.at(row, 7) == "abc123"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "writes health event to database", %{db_path: db_path} do
      event = %{
        service_name: "test_service",
        node_id: "node1",
        event_type: "health",
        severity: "info",
        message: "Service healthy",
        correlation_id: nil,
        metadata: %{
          status: "healthy",
          cpu_percent: 45.2,
          memory_mb: 512,
          queue_depth: 0
        }
      }

      assert :ok = SqliteWriter.write_event(db_path, event)

      # Verify event was written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT * FROM events WHERE service_name = ? AND event_type = ?"
        )

      :ok = Exqlite.Sqlite3.bind(statement, ["test_service", "health"])
      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) == 1

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "writes metric event to database", %{db_path: db_path} do
      event = %{
        service_name: "test_service",
        node_id: "node1",
        event_type: "metric",
        severity: "info",
        message: "Request processed",
        correlation_id: "xyz789",
        metadata: %{
          duration_ms: 125,
          status_code: 200,
          endpoint: "/api/users"
        }
      }

      assert :ok = SqliteWriter.write_event(db_path, event)
    end

    test "handles missing optional fields gracefully", %{db_path: db_path} do
      event = %{
        service_name: "test_service",
        node_id: "node1",
        event_type: "error",
        severity: "warning",
        message: "Minor issue",
        correlation_id: nil,
        metadata: nil
      }

      assert :ok = SqliteWriter.write_event(db_path, event)
    end

    test "encodes metadata as JSON", %{db_path: db_path} do
      event = %{
        service_name: "test_service",
        node_id: "node1",
        event_type: "error",
        severity: "error",
        message: "Complex metadata",
        correlation_id: nil,
        metadata: %{
          nested: %{
            data: [1, 2, 3],
            flag: true
          }
        }
      }

      assert :ok = SqliteWriter.write_event(db_path, event)

      # Verify metadata was stored as JSON
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT metadata FROM events WHERE message = ?")

      :ok = Exqlite.Sqlite3.bind(statement, ["Complex metadata"])
      {:ok, [[json_string]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert {:ok, decoded} = JSON.decode(json_string)
      assert decoded["nested"]["data"] == [1, 2, 3]
      assert decoded["nested"]["flag"] == true

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "batch operations" do
    setup %{db_path: db_path} do
      {:ok, _} = SqliteWriter.init_database(db_path)
      {:ok, db_path: db_path}
    end

    test "writes multiple events efficiently", %{db_path: db_path} do
      events =
        for i <- 1..100 do
          %{
            service_name: "test_service",
            node_id: "node1",
            event_type: "metric",
            severity: "info",
            message: "Event #{i}",
            correlation_id: "batch_#{i}",
            metadata: %{index: i}
          }
        end

      # Should complete quickly even with many events
      for event <- events do
        assert :ok = SqliteWriter.write_event(db_path, event)
      end

      # Verify all were written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events")
      {:ok, [[count]]} = Exqlite.Sqlite3.fetch_all(conn, statement)
      assert count == 100

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end
end
