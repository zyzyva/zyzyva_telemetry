defmodule ZyzyvaTelemetry.MonitoringSupervisor do
  @moduledoc """
  Supervisor for ZyzyvaTelemetry monitoring processes.

  Add this to your application's supervision tree:

      children = [
        # ... other children
        {ZyzyvaTelemetry.MonitoringSupervisor, 
         service_name: "my_app",
         repo: MyApp.Repo,
         broadway_pipelines: [MyApp.Pipeline.Broadway]}
      ]
  """

  use Supervisor

  @doc """
  Starts the monitoring supervisor.

  ## Options

    * `:service_name` - The application name (defaults to app from Mix.Project)
    * `:repo` - The Ecto repo module for database health checks (optional)
    * `:broadway_pipelines` - List of Broadway pipeline modules to monitor (optional)
    * `:extra_health_checks` - Additional health check functions to merge
    * `:health_interval_ms` - Health check interval (defaults to 30_000)
    * `:db_path` - Database path (defaults to /var/lib/monitoring/events.db)
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Initialize the database first (synchronously)
    db_path = init_database(opts)

    # Build configuration for health reporter
    health_config = build_health_config(opts, db_path)

    # Configure the error logger
    ZyzyvaTelemetry.ErrorLogger.configure(%{
      service_name: health_config.service_name,
      node_id: health_config.node_id,
      db_path: db_path
    })

    children = [
      {ZyzyvaTelemetry.HealthReporter, health_config}
      # Data retention will be handled by the aggregator service
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp init_database(opts) do
    db_path = determine_db_path(opts)

    case ZyzyvaTelemetry.SqliteWriter.init_database(db_path) do
      {:ok, :database_initialized} ->
        db_path

      {:error, reason} ->
        # Fall back to temp directory if primary path fails
        fallback_path = "/tmp/monitoring_#{opts[:service_name]}/events.db"

        case ZyzyvaTelemetry.SqliteWriter.init_database(fallback_path) do
          {:ok, :database_initialized} ->
            :logger.warning("Using fallback monitoring path: #{fallback_path}")
            fallback_path

          {:error, _} ->
            raise "Failed to initialize monitoring database: #{inspect(reason)}"
        end
    end
  end

  defp determine_db_path(opts) do
    opts[:db_path] ||
      Application.get_env(opts[:app_name] || :zyzyva_telemetry, :db_path) ||
      default_db_path()
  end

  defp default_db_path do
    if Mix.env() == :test do
      "/tmp/monitoring_test/events.db"
    else
      "/var/lib/monitoring/events.db"
    end
  rescue
    # Mix might not be available in releases
    _ -> "/var/lib/monitoring/events.db"
  end

  defp build_health_config(opts, db_path) do
    app_name = opts[:app_name] || opts[:service_name] || infer_app_name()

    %{
      service_name: to_string(app_name),
      node_id: opts[:node_id] || to_string(node()),
      db_path: db_path,
      interval_ms: opts[:health_interval_ms] || 30_000,
      health_check_fn: build_health_check_fn(opts)
    }
  end

  defp build_health_check_fn(opts) do
    repo = opts[:repo]
    broadway_pipelines = opts[:broadway_pipelines] || []
    extra_checks = opts[:extra_health_checks] || %{}

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

      # Add Broadway/RabbitMQ checks if pipelines provided
      base_health =
        if broadway_pipelines != [] do
          rabbitmq_connected = check_broadway_pipelines(broadway_pipelines)
          Map.put(base_health, :rabbitmq_connected, rabbitmq_connected)
        else
          base_health
        end

      # Execute extra health checks and merge their results
      extra_results =
        Enum.reduce(extra_checks, %{}, fn {_key, value}, acc ->
          result = if is_function(value, 0), do: value.(), else: value
          # If the result is a map, merge it directly
          if is_map(result), do: Map.merge(acc, result), else: acc
        end)

      # Merge and determine overall status
      merged = Map.merge(base_health, extra_results)
      overall_status = determine_overall_status(merged)
      Map.put(merged, :status, overall_status)
    end
  end

  defp check_database(repo) do
    try do
      repo.query!("SELECT 1")
      true
    rescue
      _ -> false
    end
  end

  defp check_memory do
    memory_mb = :erlang.memory(:total) / 1_024 / 1_024

    status =
      cond do
        memory_mb > 4096 -> :critical
        memory_mb > 2048 -> :warning
        true -> :ok
      end

    %{
      mb: Float.round(memory_mb, 2),
      status: status
    }
  end

  defp check_processes do
    count = length(Process.list())

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

  defp check_broadway_pipelines(pipelines) do
    Enum.all?(pipelines, fn pipeline ->
      case Process.whereis(pipeline) do
        nil -> false
        _pid -> true
      end
    end)
  end

  defp determine_overall_status(health_data) do
    cond do
      health_data[:memory][:status] == :critical -> :critical
      health_data[:processes][:status] == :critical -> :critical
      health_data[:database_connected] == false -> :critical
      health_data[:memory][:status] == :warning -> :degraded
      health_data[:processes][:status] == :warning -> :degraded
      true -> :healthy
    end
  end

  defp infer_app_name do
    # Try to infer from Mix.Project or loaded applications
    case Mix.Project.get() do
      nil -> infer_from_loaded_apps()
      module -> module.project()[:app] || infer_from_loaded_apps()
    end
  rescue
    _ -> infer_from_loaded_apps()
  end

  defp infer_from_loaded_apps do
    Application.loaded_applications()
    |> Enum.reverse()
    |> Enum.find_value(fn {app, _desc, _vsn} ->
      app_str = to_string(app)
      system_apps = ~w[
        kernel stdlib elixir logger iex mix ex_unit compiler crypto ssl
        public_key asn1 inets telemetry telemetry_poller telemetry_metrics
        exqlite db_connection ecto ecto_sql postgrex phoenix phoenix_html
        phoenix_live_view phoenix_pubsub plug plug_crypto mime phoenix_ecto
        decimal ranch cowboy bandit thousand_island zyzyva_telemetry
      ]

      if to_string(app) not in system_apps and
           not String.starts_with?(app_str, "zyzyva_") do
        app
      else
        nil
      end
    end) || :unknown_app
  end
end
