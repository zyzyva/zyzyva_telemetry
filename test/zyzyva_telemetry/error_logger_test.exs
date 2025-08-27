defmodule ZyzyvaTelemetry.ErrorLoggerTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias ZyzyvaTelemetry.ErrorLogger

  @test_db_path "/tmp/test_error_monitoring_#{System.unique_integer([:positive])}.db"

  setup do
    # Initialize test database
    File.rm(@test_db_path)
    {:ok, _} = ZyzyvaTelemetry.SqliteWriter.init_database(@test_db_path)

    on_exit(fn ->
      File.rm(@test_db_path)
    end)

    {:ok, db_path: @test_db_path}
  end

  describe "log_error/3" do
    test "logs simple error message", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      assert :ok = ErrorLogger.log_error("Something went wrong")

      # Give it a moment to write
      Process.sleep(10)

      # Verify error was written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT * FROM events WHERE event_type = 'error'")

      {:ok, result} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert length(result) == 1
      [row] = result
      # event_type
      assert Enum.at(row, 4) == "error"
      # severity
      assert Enum.at(row, 5) == "error"
      # message
      assert Enum.at(row, 6) == "Something went wrong"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "logs error with metadata", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      metadata = %{
        module: "MyModule",
        function: "process/1",
        line: 42,
        user_id: 123
      }

      assert :ok = ErrorLogger.log_error("Failed to process", metadata)

      Process.sleep(10)

      # Verify metadata was stored
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT metadata FROM events WHERE event_type = 'error'")

      {:ok, [[json_string]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert {:ok, decoded} = JSON.decode(json_string)
      assert decoded["module"] == "MyModule"
      assert decoded["function"] == "process/1"
      assert decoded["line"] == 42
      assert decoded["user_id"] == 123

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "logs error with correlation ID", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      assert :ok = ErrorLogger.log_error("Request failed", %{}, "req_12345")

      Process.sleep(10)

      # Verify correlation ID was stored
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT correlation_id FROM events WHERE event_type = 'error'"
        )

      {:ok, [[correlation_id]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert correlation_id == "req_12345"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "log_exception/4" do
    test "logs exception with stack trace", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      # Create a real exception with stack trace
      try do
        raise RuntimeError, "Test exception"
      rescue
        e ->
          stacktrace = __STACKTRACE__
          assert :ok = ErrorLogger.log_exception(e, stacktrace, "Processing failed")
      end

      Process.sleep(10)

      # Verify exception was logged with stack trace
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT message, metadata FROM events WHERE event_type = 'error'"
        )

      {:ok, [[message, metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert message == "Processing failed: %RuntimeError{message: \"Test exception\"}"

      assert {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["error_type"] == "RuntimeError"
      assert metadata["error_message"] == "Test exception"
      assert is_list(metadata["stacktrace"])
      assert length(metadata["stacktrace"]) > 0

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end

    test "logs exception with additional metadata", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      # Use apply to avoid compile-time warning about division by zero
      capture_log(fn ->
        try do
          apply(Kernel, :/, [1, 0])
        rescue
          e ->
            stacktrace = __STACKTRACE__
            metadata = %{request_id: "req_999", endpoint: "/api/divide"}
            assert :ok = ErrorLogger.log_exception(e, stacktrace, "Math operation failed", metadata)
        end
      end)

      Process.sleep(10)

      # Verify additional metadata was included
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT metadata FROM events WHERE event_type = 'error'")

      {:ok, [[metadata_json]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert {:ok, metadata} = JSON.decode(metadata_json)
      assert metadata["error_type"] == "ArithmeticError"
      assert metadata["request_id"] == "req_999"
      assert metadata["endpoint"] == "/api/divide"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "log_warning/2" do
    test "logs warning with warning severity", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      assert :ok = ErrorLogger.log_warning("This is a warning")

      Process.sleep(10)

      # Verify warning was logged with correct severity
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(
          conn,
          "SELECT severity, message FROM events WHERE event_type = 'error'"
        )

      {:ok, [[severity, message]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert severity == "warning"
      assert message == "This is a warning"

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "batch logging" do
    test "can log multiple errors quickly", %{db_path: db_path} do
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)

      # Log 50 errors rapidly
      for i <- 1..50 do
        ErrorLogger.log_error("Error #{i}", %{index: i})
      end

      Process.sleep(100)

      # Verify all were written
      {:ok, conn} = Exqlite.Sqlite3.open(db_path)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(conn, "SELECT COUNT(*) FROM events WHERE event_type = 'error'")

      {:ok, [[count]]} = Exqlite.Sqlite3.fetch_all(conn, statement)

      assert count == 50

      Exqlite.Sqlite3.release(conn, statement)
      Exqlite.Sqlite3.close(conn)
    end
  end

  describe "configuration" do
    test "requires configuration before use", %{db_path: db_path} do
      # Clear any previous configuration
      ErrorLogger.clear_configuration()

      # Should return error when not configured
      assert {:error, :not_configured} = ErrorLogger.log_error("Unconfigured error")

      # Configure and try again
      config = %{
        service_name: "test_service",
        node_id: "test_node",
        db_path: db_path
      }

      ErrorLogger.configure(config)
      assert :ok = ErrorLogger.log_error("Configured error")
    end
  end
end
