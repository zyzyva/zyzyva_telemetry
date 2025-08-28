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

  describe "delete_old_forwarded_events/2" do
    setup %{db_path: db_path} do
      {:ok, _} = SqliteWriter.init_database(db_path)

      # Create test events with different timestamps and forwarded states
      now = System.system_time(:second)
      # 8 days ago
      old_time = now - 8 * 24 * 60 * 60
      # 2 days ago
      recent_time = now - 2 * 24 * 60 * 60

      # Write old forwarded events (should be deleted)
      for i <- 1..5 do
        write_test_event(db_path, "old_forwarded_#{i}", old_time, true)
      end

      # Write old unforwarded events (should NOT be deleted)
      for i <- 1..3 do
        write_test_event(db_path, "old_unforwarded_#{i}", old_time, false)
      end

      # Write recent forwarded events (should NOT be deleted)
      for i <- 1..4 do
        write_test_event(db_path, "recent_forwarded_#{i}", recent_time, true)
      end

      {:ok, db_path: db_path, cutoff_time: now - 7 * 24 * 60 * 60}
    end

    test "deletes only old forwarded events", %{db_path: db_path, cutoff_time: cutoff} do
      # Delete events older than 7 days that are forwarded
      assert {:ok, 5} = SqliteWriter.delete_old_forwarded_events(db_path, cutoff)

      # Verify correct events remain
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      # Check total count
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events")
      {:ok, [[total]]} = Exqlite.Sqlite3.fetch_all(conn, statement)
      # 3 old unforwarded + 4 recent forwarded
      assert total == 7
      Exqlite.Sqlite3.release(conn, statement)

      # Check old unforwarded still exist
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT COUNT(*) FROM events WHERE message LIKE 'old_unforwarded_%'"
        )

      {:ok, [[old_unforwarded]]} = Exqlite.Sqlite3.fetch_all(conn, statement)
      assert old_unforwarded == 3
      Exqlite.Sqlite3.release(conn, statement)

      # Check recent forwarded still exist
      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT COUNT(*) FROM events WHERE message LIKE 'recent_forwarded_%'"
        )

      {:ok, [[recent_forwarded]]} = Exqlite.Sqlite3.fetch_all(conn, statement)
      assert recent_forwarded == 4
      Exqlite.Sqlite3.release(conn, statement)

      Exqlite.Sqlite3.close(conn)
    end

    test "returns 0 when no events to delete", %{db_path: db_path} do
      # Delete with very old timestamp - nothing should be deleted
      # (all events are newer than this ancient timestamp)
      # Unix timestamp from 1970
      ancient_cutoff = 1000
      assert {:ok, 0} = SqliteWriter.delete_old_forwarded_events(db_path, ancient_cutoff)
    end

    test "handles empty database", %{db_path: db_path} do
      # Clear all events first
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM events")
      Exqlite.Sqlite3.close(conn)

      # Should handle gracefully
      assert {:ok, 0} =
               SqliteWriter.delete_old_forwarded_events(db_path, System.system_time(:second))
    end
  end

  describe "vacuum_database/1" do
    setup %{db_path: db_path} do
      {:ok, _} = SqliteWriter.init_database(db_path)

      # Create and delete many events to create space to reclaim
      for i <- 1..1000 do
        SqliteWriter.write_event(db_path, %{
          service_name: "vacuum_test",
          node_id: "node1",
          event_type: "test",
          severity: "info",
          message: "Event #{i} with some padding text to increase size",
          correlation_id: nil,
          metadata: %{data: String.duplicate("x", 100)}
        })
      end

      # Mark all as forwarded and delete them
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      :ok = Exqlite.Sqlite3.execute(conn, "UPDATE events SET forwarded = 1")
      Exqlite.Sqlite3.close(conn)

      {:ok, _} =
        SqliteWriter.delete_old_forwarded_events(db_path, System.system_time(:second) + 1)

      {:ok, db_path: db_path}
    end

    test "successfully runs vacuum", %{db_path: db_path} do
      # Get file size before vacuum (may or may not change after vacuum)
      _size_before = File.stat!(db_path).size

      # Run vacuum
      assert :ok = SqliteWriter.vacuum_database(db_path)

      # File should still exist and be valid
      assert File.exists?(db_path)

      # Verify database is still functional
      assert :ok =
               SqliteWriter.write_event(db_path, %{
                 service_name: "post_vacuum",
                 node_id: "node1",
                 event_type: "test",
                 severity: "info",
                 message: "Test after vacuum",
                 correlation_id: nil,
                 metadata: nil
               })

      # In most cases, file size should be smaller after vacuum
      # (though not guaranteed if the database was already optimized)
      size_after = File.stat!(db_path).size
      assert size_after > 0
    end

    test "handles database that doesn't need vacuum", %{db_path: db_path} do
      # Clear the database
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM events")
      Exqlite.Sqlite3.close(conn)

      # Vacuum should still work even with empty database
      assert :ok = SqliteWriter.vacuum_database(db_path)
    end
  end

  # Helper function to write test events with specific timestamp and forwarded status
  defp write_test_event(db_path, message, timestamp, forwarded) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    sql = """
    INSERT INTO events (timestamp, service_name, node_id, event_type, severity, message, forwarded)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)

    :ok =
      Exqlite.Sqlite3.bind(statement, [
        timestamp,
        "test_service",
        "test_node",
        "test",
        "info",
        message,
        if(forwarded, do: 1, else: 0)
      ])

    :done = Exqlite.Sqlite3.step(conn, statement)
    :ok = Exqlite.Sqlite3.release(conn, statement)
    :ok = Exqlite.Sqlite3.close(conn)
  end
end
