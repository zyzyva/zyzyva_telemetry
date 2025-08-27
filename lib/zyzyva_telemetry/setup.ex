defmodule ZyzyvaTelemetry.Setup do
  @moduledoc """
  Setup utilities for initializing the ZyzyvaTelemetry database.

  This module can be called from releases to set up the required
  database structure with proper permissions.

  ## Usage from release

      # In your release's env.sh or when starting:
      ./my_app eval "ZyzyvaTelemetry.Setup.init()"
      
      # Or with custom path:
      ./my_app eval "ZyzyvaTelemetry.Setup.init('/custom/path/events.db')"
  """

  @default_db_path "/var/lib/monitoring/events.db"

  @doc """
  Initializes the database, creating directories and tables as needed.

  If the default path requires elevated permissions, this will attempt
  to use sudo to create the directory structure.
  """
  def init(db_path \\ @default_db_path) do
    IO.puts("Setting up ZyzyvaTelemetry database at: #{db_path}")

    case setup_database(db_path) do
      :ok ->
        IO.puts("✓ Database initialized successfully at #{db_path}")
        :ok

      {:error, reason} ->
        IO.puts("✗ Failed to initialize database: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sets up the database with sudo if needed.
  Returns :ok | {:error, reason}
  """
  def setup_database(db_path) do
    db_dir = Path.dirname(db_path)

    cond do
      # Directory exists and is writable
      File.exists?(db_dir) and writable?(db_dir) ->
        init_db_tables(db_path)

      # Directory exists but not writable (needs sudo)
      File.exists?(db_dir) and not writable?(db_dir) ->
        IO.puts("Directory #{db_dir} exists but is not writable.")
        IO.puts("Attempting to set permissions with sudo...")
        setup_with_sudo(db_path)

      # Directory doesn't exist
      true ->
        IO.puts("Directory #{db_dir} does not exist.")
        IO.puts("Attempting to create with sudo...")
        setup_with_sudo(db_path)
    end
  end

  defp setup_with_sudo(db_path) do
    db_dir = Path.dirname(db_path)
    current_user = System.get_env("USER") || "nobody"

    commands = [
      # Create directory
      "sudo mkdir -p #{db_dir}",
      # Set ownership to current user
      "sudo chown #{current_user}:#{current_user} #{db_dir}",
      # Set permissions (user read/write/execute)
      "sudo chmod 755 #{db_dir}"
    ]

    IO.puts("The following commands will be executed:")
    Enum.each(commands, &IO.puts("  #{&1}"))
    IO.puts("")

    # Check if we're in an interactive terminal
    if System.get_env("TERM") do
      IO.puts("Please enter your sudo password when prompted.")

      # Execute commands
      results =
        Enum.map(commands, fn cmd ->
          System.cmd("sh", ["-c", cmd], into: IO.stream(:stdio, :line))
        end)

      # Check if all succeeded
      if Enum.all?(results, fn {_, code} -> code == 0 end) do
        # Now initialize the database
        init_db_tables(db_path)
      else
        {:error, :sudo_commands_failed}
      end
    else
      IO.puts("Not running in an interactive terminal.")
      IO.puts("Please run these commands manually:")
      Enum.each(commands, &IO.puts("  #{&1}"))
      {:error, :manual_setup_required}
    end
  end

  defp init_db_tables(db_path) do
    case ZyzyvaTelemetry.SqliteWriter.init_database(db_path) do
      {:ok, _} ->
        :ok

      error ->
        error
    end
  end

  defp writable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} ->
        access in [:write, :read_write]

      _ ->
        false
    end
  end

  @doc """
  Provides a shell script that can be used to set up the database.
  Useful for provisioning scripts or Docker containers.
  """
  def generate_setup_script(db_path \\ @default_db_path) do
    """
    #!/bin/bash
    # ZyzyvaTelemetry Database Setup Script

    DB_PATH="#{db_path}"
    DB_DIR="$(dirname "$DB_PATH")"

    echo "Setting up ZyzyvaTelemetry database at: $DB_PATH"

    # Create directory if it doesn't exist
    if [ ! -d "$DB_DIR" ]; then
        echo "Creating directory: $DB_DIR"
        sudo mkdir -p "$DB_DIR"
    fi

    # Set ownership to the application user
    APP_USER="${APP_USER:-$USER}"
    echo "Setting ownership to: $APP_USER"
    sudo chown "$APP_USER:$APP_USER" "$DB_DIR"
    sudo chmod 755 "$DB_DIR"

    echo "Directory setup complete. The application will create the database on first run."
    """
  end
end
