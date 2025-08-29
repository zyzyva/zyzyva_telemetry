db_path = "/tmp/test_changes.db"
File.rm(db_path)

{:ok, conn} = Exqlite.Sqlite3.open(db_path)
:ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")
{:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "INSERT INTO test (value) VALUES (?)")
:ok = Exqlite.Sqlite3.bind(stmt, ["test"])
:done = Exqlite.Sqlite3.step(conn, stmt)
IO.inspect(Exqlite.Sqlite3.changes(conn), label: "Changes result")
:ok = Exqlite.Sqlite3.release(conn, stmt)
:ok = Exqlite.Sqlite3.close(conn)
File.rm(db_path)
