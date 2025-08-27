#!/usr/bin/env elixir

# ZyzyvaTelemetry Database Setup Script
# 
# This script can be run directly with Elixir or included in a release.
# Usage:
#   elixir setup_db.exs [db_path]
#
# Or from a release:
#   ./my_app eval "Code.eval_file('path/to/setup_db.exs')"

db_path = System.argv() |> List.first() || "/var/lib/monitoring/events.db"

IO.puts("ZyzyvaTelemetry Database Setup")
IO.puts("=" <> String.duplicate("=", 40))

case ZyzyvaTelemetry.Setup.init(db_path) do
  :ok ->
    System.halt(0)
    
  {:error, _reason} ->
    System.halt(1)
end