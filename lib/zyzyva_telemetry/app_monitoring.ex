defmodule ZyzyvaTelemetry.AppMonitoring do
  @moduledoc """
  Simplified monitoring setup for Phoenix applications.
  Provides standard health checks and DRY initialization.
  """

  @doc """
  Initialize monitoring with minimal configuration.

  ## Options

    * `:app_name` - The application name (defaults to app from Mix.Project)
    * `:repo` - The Ecto repo module for database health checks (optional)
    * `:extra_health_checks` - Additional health check functions to merge
    * `:health_interval_ms` - Health check interval (defaults to 30_000)
    * `:db_path` - Database path (defaults to /var/lib/monitoring/events.db)

  ## Example

      ZyzyvaTelemetry.AppMonitoring.init(
        repo: MyApp.Repo,
        extra_health_checks: %{
          redis_connected: &check_redis/0
        }
      )
  """
  def init(opts \\ []) do
    app_name = opts[:app_name] || infer_app_name()
    repo = opts[:repo]
    extra_checks = opts[:extra_health_checks] || %{}
    health_interval = opts[:health_interval_ms] || 30_000

    # Get db_path from app config or opts, with fallback
    db_path =
      opts[:db_path] ||
        Application.get_env(app_name, :monitoring_db_path) ||
        default_db_path()

    config = %{
      service_name: to_string(app_name),
      db_path: db_path,
      health_check_fn: build_health_check_fn(repo, extra_checks),
      health_interval_ms: health_interval
    }

    # Initialize ZyzyvaTelemetry
    ZyzyvaTelemetry.init(config)
    :logger.info("ZyzyvaTelemetry monitoring initialized for #{app_name}")
  end

  @doc """
  Get the current health status for use in health endpoints.
  Returns the most recent health check data.
  """
  def get_health_status do
    case ZyzyvaTelemetry.get_health() do
      {:error, :health_reporter_not_running} ->
        # Return basic health info if reporter not running
        {:ok,
         %{
           status: :unknown,
           message: "Health reporter not initialized",
           timestamp: DateTime.utc_now()
         }}

      health_data when is_map(health_data) ->
        # Health reporter returns data directly
        {:ok, health_data}

      other ->
        {:error, other}
    end
  end

  @doc """
  Standard database health check using Ecto repo.
  """
  def check_database(nil), do: nil

  def check_database(repo) do
    try do
      repo.query!("SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  @doc """
  Standard memory health check.
  Returns memory in MB and a status indicator.
  """
  def check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024

    # Simple thresholds - could be made configurable
    status =
      cond do
        # > 4GB
        memory_mb > 4096 -> :critical
        # > 2GB
        memory_mb > 2048 -> :warning
        true -> :ok
      end

    %{
      mb: Float.round(memory_mb, 2),
      status: status
    }
  end

  @doc """
  Standard process count health check.
  """
  def check_processes do
    count = length(Process.list())

    # Simple thresholds
    status =
      cond do
        count > 10_000 -> :critical
        count > 5_000 -> :warning
        true -> :ok
      end

    %{
      count: count,
      status: status
    }
  end

  @doc """
  Check if a named GenServer/Broadway pipeline is running.
  """
  def check_process(process_name) do
    case Process.whereis(process_name) do
      nil -> false
      _pid -> true
    end
  end

  # Private functions

  defp infer_app_name do
    # Try multiple methods to infer the app name
    cond do
      # 1. Check if we're in a Mix project
      mix_app = get_mix_app_name() ->
        mix_app

      # 2. Try to get from currently running OTP application
      otp_app = get_otp_app_name() ->
        otp_app

      # 3. Last resort - get from loaded applications
      loaded_app = get_from_loaded_apps() ->
        loaded_app

      true ->
        raise "Could not infer application name. Please provide :app_name option"
    end
  end

  defp get_mix_app_name do
    case Mix.Project.get() do
      nil -> nil
      module -> module.project()[:app]
    end
  rescue
    # Mix might not be available in releases
    _ -> nil
  end

  defp get_otp_app_name do
    # Try to get the application that's currently starting
    case Process.get(:"$initial_call") do
      {mod, _, _} when is_atom(mod) ->
        # Module name usually matches app name (e.g., Botify.Application -> :botify)
        mod
        |> Module.split()
        |> List.first()
        |> String.downcase()
        |> String.to_atom()

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp get_from_loaded_apps do
    # Get the most recently started non-system application
    # This works because user apps are typically started after system apps
    Application.loaded_applications()
    |> Enum.reverse()
    |> Enum.find_value(fn {app, _desc, _vsn} ->
      app_str = to_string(app)
      # Skip system/dependency apps
      # These are common Elixir/Erlang system and library apps
      system_apps = [
        :kernel,
        :stdlib,
        :elixir,
        :logger,
        :iex,
        :mix,
        :ex_unit,
        :compiler,
        :crypto,
        :ssl,
        :public_key,
        :asn1,
        :inets,
        # Database/monitoring deps
        :telemetry,
        :telemetry_poller,
        :telemetry_metrics,
        :exqlite,
        :db_connection,
        :ecto,
        :ecto_sql,
        :postgrex,
        # Phoenix deps
        :phoenix,
        :phoenix_html,
        :phoenix_live_view,
        :phoenix_pubsub,
        :plug,
        :plug_crypto,
        :mime,
        :phoenix_ecto,
        # Common libraries
        :decimal,
        :ranch,
        :cowboy,
        :bandit,
        :thousand_island,
        # Our monitoring lib
        :zyzyva_telemetry
      ]

      if app not in system_apps and not String.starts_with?(app_str, "zyzyva_") do
        app
      else
        nil
      end
    end)
  end

  defp default_db_path do
    if Mix.env() == :test do
      "/tmp/monitoring_test/events.db"
    else
      "/var/lib/monitoring/events.db"
    end
  end

  defp build_health_check_fn(repo, extra_checks) do
    fn ->
      # Build standard health checks
      base_health = %{
        status: :healthy,
        timestamp: DateTime.utc_now(),
        memory: check_memory(),
        processes: check_processes()
      }

      # Add database check if repo provided
      base_health =
        if repo do
          Map.put(base_health, :database_connected, check_database(repo))
        else
          base_health
        end

      # Execute extra health checks if they're functions
      extra_results =
        Enum.map(extra_checks, fn {key, value} ->
          result =
            if is_function(value, 0) do
              value.()
            else
              value
            end

          {key, result}
        end)
        |> Map.new()

      # Merge executed health checks
      merged = Map.merge(base_health, extra_results)

      # Determine overall status based on checks
      overall_status = determine_overall_status(merged)
      Map.put(merged, :status, overall_status)
    end
  end

  defp determine_overall_status(health_data) do
    cond do
      # Check for any critical conditions
      health_data[:memory][:status] == :critical -> :critical
      health_data[:processes][:status] == :critical -> :critical
      health_data[:database_connected] == false -> :critical
      # Check for warnings
      health_data[:memory][:status] == :warning -> :degraded
      health_data[:processes][:status] == :warning -> :degraded
      # Otherwise healthy
      true -> :healthy
    end
  end
end
