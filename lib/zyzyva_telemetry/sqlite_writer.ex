defmodule ZyzyvaTelemetry.SqliteWriter do
  @moduledoc """
  Handles writing monitoring events directly to SQLite database.
  This module provides low-level SQLite operations without Ecto.
  """

  @events_table_ddl """
  CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    service_name TEXT NOT NULL,
    node_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    severity TEXT NOT NULL,
    message TEXT NOT NULL,
    correlation_id TEXT,
    metadata TEXT,
    forwarded INTEGER DEFAULT 0
  );
  """

  @events_index_ddl """
  CREATE INDEX IF NOT EXISTS idx_events_forwarded ON events(forwarded);
  CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
  CREATE INDEX IF NOT EXISTS idx_events_correlation ON events(correlation_id);
  CREATE INDEX IF NOT EXISTS idx_events_service ON events(service_name, event_type);
  """

  @doc """
  Initializes the database with required tables and indexes.
  Creates the database file if it doesn't exist.
  """
  def init_database(db_path) do
    # Ensure parent directory exists
    db_dir = Path.dirname(db_path)
    File.mkdir_p!(db_dir)

    with {:ok, conn} <- open_connection(db_path),
         :ok <- configure_pragmas(conn),
         :ok <- create_tables(conn),
         :ok <- create_indexes(conn),
         :ok <- Exqlite.Sqlite3.close(conn) do
      {:ok, :database_initialized}
    else
      {:error, reason} -> {:error, {:database_init_failed, reason}}
    end
  end

  @doc """
  Writes a monitoring event to the database.

  Event map should contain:
  - service_name: Name of the service
  - node_id: Node identifier
  - event_type: Type of event (error, health, metric, trace)
  - severity: Severity level (error, warning, info, debug)
  - message: Event message
  - correlation_id: Optional correlation ID for tracing
  - metadata: Optional map of additional data (will be JSON encoded)
  """
  def write_event(db_path, event) do
    metadata_json =
      case event[:metadata] do
        nil -> nil
        data -> JSON.encode!(data)
      end

    sql = """
    INSERT INTO events (service_name, node_id, event_type, severity, message, correlation_id, metadata)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    """

    params = [
      event.service_name,
      event.node_id,
      event.event_type,
      event.severity,
      event.message,
      event[:correlation_id],
      metadata_json
    ]

    with {:ok, conn} <- open_connection(db_path),
         {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(statement, params),
         :done <- Exqlite.Sqlite3.step(conn, statement),
         :ok <- Exqlite.Sqlite3.release(conn, statement),
         :ok <- Exqlite.Sqlite3.close(conn) do
      :ok
    else
      error ->
        # Try to clean up connection on error
        try do
          Exqlite.Sqlite3.close(db_path)
        rescue
          _ -> :ok
        end

        {:error, error}
    end
  end

  @doc """
  Writes multiple events in a single transaction for better performance.
  """
  def write_events(db_path, events) when is_list(events) do
    with {:ok, conn} <- open_connection(db_path),
         :ok <- Exqlite.Sqlite3.execute(conn, "BEGIN TRANSACTION") do
      sql = """
      INSERT INTO events (service_name, node_id, event_type, severity, message, correlation_id, metadata)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """

      {:ok, statement} = Exqlite.Sqlite3.prepare(conn, sql)

      results =
        Enum.map(events, fn event ->
          metadata_json =
            case event[:metadata] do
              nil -> nil
              data -> JSON.encode!(data)
            end

          params = [
            event.service_name,
            event.node_id,
            event.event_type,
            event.severity,
            event.message,
            event[:correlation_id],
            metadata_json
          ]

          with :ok <- Exqlite.Sqlite3.bind(statement, params),
               :done <- Exqlite.Sqlite3.step(conn, statement),
               :ok <- Exqlite.Sqlite3.reset(statement) do
            :ok
          else
            error -> {:error, error}
          end
        end)

      Exqlite.Sqlite3.release(conn, statement)

      if Enum.all?(results, &(&1 == :ok)) do
        :ok = Exqlite.Sqlite3.execute(conn, "COMMIT")
        :ok = Exqlite.Sqlite3.close(conn)
        :ok
      else
        :ok = Exqlite.Sqlite3.execute(conn, "ROLLBACK")
        :ok = Exqlite.Sqlite3.close(conn)
        {:error, :batch_write_failed}
      end
    else
      error -> {:error, error}
    end
  end

  # Private functions

  defp open_connection(db_path) do
    case Exqlite.Sqlite3.open(db_path) do
      {:ok, conn} ->
        # Always set WAL mode for connections (it's persistent but doesn't hurt)
        # Use NORMAL synchronous for better performance with WAL
        case Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL") do
          {:ok, _} -> {:ok, conn}
          # Continue even if pragma fails (DB might be read-only)
          _ -> {:ok, conn}
        end

      error ->
        error
    end
  end

  defp configure_pragmas(conn) do
    pragmas = [
      # Enable Write-Ahead Logging for better concurrency
      "PRAGMA journal_mode=WAL",
      # Synchronous=NORMAL is safe with WAL (faster than FULL)
      "PRAGMA synchronous=NORMAL",
      # Cache size 10MB (default is 2MB)
      "PRAGMA cache_size=-10000",
      # Enable memory-mapped I/O (up to 256MB)
      "PRAGMA mmap_size=268435456",
      # Checkpoint WAL every 1000 pages (4MB with 4KB pages)
      "PRAGMA wal_autocheckpoint=1000",
      # Keep temporary tables in memory
      "PRAGMA temp_store=MEMORY"
    ]

    Enum.reduce_while(pragmas, :ok, fn pragma, _acc ->
      case Exqlite.Sqlite3.execute(conn, pragma) do
        :ok -> {:cont, :ok}
        # Some pragmas return values
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp create_tables(conn) do
    case Exqlite.Sqlite3.execute(conn, @events_table_ddl) do
      :ok -> :ok
      error -> error
    end
  end

  defp create_indexes(conn) do
    # Split the index DDL and execute each statement
    @events_index_ddl
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while(:ok, fn index_sql, _acc ->
      case Exqlite.Sqlite3.execute(conn, index_sql) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Marks events as forwarded (for use by aggregator).
  This allows the retention policy to safely delete forwarded events.
  """
  def mark_events_forwarded(db_path, event_ids) when is_list(event_ids) do
    placeholders = Enum.map_join(event_ids, ",", fn _ -> "?" end)
    sql = "UPDATE events SET forwarded = 1 WHERE id IN (#{placeholders})"

    with {:ok, conn} <- open_connection(db_path),
         {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(statement, event_ids),
         :done <- Exqlite.Sqlite3.step(conn, statement),
         :ok <- Exqlite.Sqlite3.release(conn, statement),
         :ok <- Exqlite.Sqlite3.close(conn) do
      :ok
    else
      error -> {:error, error}
    end
  end

  @doc """
  Fetches unfowarded events for aggregation.
  Returns up to `limit` events that haven't been forwarded yet.
  """
  def get_unforwarded_events(db_path, limit \\ 1000) do
    sql = """
    SELECT id, timestamp, service_name, node_id, event_type, 
           severity, message, correlation_id, metadata
    FROM events
    WHERE forwarded = 0
    ORDER BY timestamp
    LIMIT ?
    """

    with {:ok, conn} <- open_connection(db_path),
         {:ok, statement} <- Exqlite.Sqlite3.prepare(conn, sql),
         :ok <- Exqlite.Sqlite3.bind(statement, [limit]),
         {:ok, rows} <- fetch_all_rows(conn, statement),
         :ok <- Exqlite.Sqlite3.release(conn, statement),
         :ok <- Exqlite.Sqlite3.close(conn) do
      events = Enum.map(rows, &row_to_event/1)
      {:ok, events}
    else
      error -> {:error, error}
    end
  end

  defp fetch_all_rows(conn, statement, acc \\ []) do
    case Exqlite.Sqlite3.step(conn, statement) do
      {:row, row} -> fetch_all_rows(conn, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp row_to_event([
         id,
         timestamp,
         service_name,
         node_id,
         event_type,
         severity,
         message,
         correlation_id,
         metadata_json
       ]) do
    metadata =
      case metadata_json do
        nil -> nil
        json -> JSON.decode!(json)
      end

    %{
      id: id,
      timestamp: timestamp,
      service_name: service_name,
      node_id: node_id,
      event_type: event_type,
      severity: severity,
      message: message,
      correlation_id: correlation_id,
      metadata: metadata
    }
  end
end
