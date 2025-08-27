defmodule ZyzyvaTelemetry.ConnectionManagementTest do
  use ExUnit.Case, async: false

  alias ZyzyvaTelemetry.SqliteWriter

  @test_db "/tmp/test_connection_#{System.unique_integer([:positive])}.db"

  setup do
    # Clean up test database after each test
    on_exit(fn ->
      File.rm(@test_db)
    end)

    {:ok, db_path: @test_db}
  end

  describe "connection management" do
    test "init_database properly closes connection", %{db_path: db_path} do
      # Initialize database
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)

      # Try to open a connection to verify it was closed
      assert {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      assert :ok = Exqlite.Sqlite3.close(conn)
    end

    test "write_event properly closes connection on success", %{db_path: db_path} do
      {:ok, :database_initialized} = SqliteWriter.init_database(db_path)

      event = %{
        service_name: "test_service",
        node_id: node(),
        event_type: "test",
        severity: "info",
        message: "Test message"
      }

      assert :ok = SqliteWriter.write_event(db_path, event)

      # Verify connection was closed by opening a new one
      assert {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      # Verify the event was written
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events")
      {:ok, [[1]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "write_event properly closes connection on error", %{db_path: db_path} do
      # Don't initialize database to cause an error

      event = %{
        service_name: "test_service",
        node_id: node(),
        event_type: "test",
        severity: "info",
        message: "Test message"
      }

      # This should fail because database doesn't exist
      assert {:error, _} = SqliteWriter.write_event(db_path, event)

      # If there were leaked connections, this would fail
      # But we should be able to initialize the database now
      assert {:ok, :database_initialized} = SqliteWriter.init_database(db_path)
    end

    test "write_events properly closes connection after batch write", %{db_path: db_path} do
      {:ok, :database_initialized} = SqliteWriter.init_database(db_path)

      events =
        for i <- 1..10 do
          %{
            service_name: "test_service",
            node_id: node(),
            event_type: "test",
            severity: "info",
            message: "Test message #{i}"
          }
        end

      assert :ok = SqliteWriter.write_events(db_path, events)

      # Verify connection was closed
      assert {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      # Verify all events were written
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events")
      {:ok, [[10]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "concurrent writes don't leak connections", %{db_path: db_path} do
      {:ok, :database_initialized} = SqliteWriter.init_database(db_path)

      # Spawn multiple concurrent writers
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            event = %{
              service_name: "test_service",
              node_id: node(),
              event_type: "test",
              severity: "info",
              message: "Concurrent message #{i}"
            }

            SqliteWriter.write_event(db_path, event)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      # Verify we can still open a connection (no leaked locks)
      assert {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      # Verify all events were written
      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events")
      {:ok, [[20]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "health reporter lifecycle" do
    test "health reporter properly manages its lifecycle" do
      db_path = "/tmp/test_health_reporter_#{System.unique_integer([:positive])}.db"

      # Initialize database
      {:ok, :database_initialized} = SqliteWriter.init_database(db_path)

      config = %{
        service_name: "test",
        node_id: node(),
        db_path: db_path,
        # Short interval for testing
        interval_ms: 50,
        health_check_fn: fn -> %{status: :healthy} end
      }

      # Start and stop the reporter
      {:ok, pid} = ZyzyvaTelemetry.HealthReporter.start_link(config)

      # Let it run for a bit
      Process.sleep(100)

      # Stop it
      GenServer.stop(pid)

      # Verify we can still access the database
      assert {:ok, conn} = Exqlite.Sqlite3.open(db_path)
      Exqlite.Sqlite3.close(conn)

      # Clean up
      File.rm(db_path)
    end
  end
end
