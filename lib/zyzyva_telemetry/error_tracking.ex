defmodule ZyzyvaTelemetry.ErrorTracking do
  @moduledoc """
  Standardized Tower configuration for ecosystem apps.

  Supports two modes:
  1. Direct HTTP push to Loki (default, recommended)
  2. File-based logging for Promtail pickup (legacy)

  Tower v0.8+ doesn't use a supervision tree - it's configured via
  Application environment and attached to the logger.

  Configuration:
  - service_name: Required - name of the service
  - loki_url: Optional - URL of Loki for direct push (e.g., "http://100.104.83.12:3100")
  - use_file_logging: Optional - Set to true to use file logging instead of HTTP push

  Examples:

      # Direct Loki push (recommended - no Promtail needed)
      {ZyzyvaTelemetry.Supervisor,
       service_name: "my_app",
       promex_module: MyApp.PromEx,
       loki_url: "http://100.104.83.12:3100"}

      # File-based logging (requires Promtail on server)
      {ZyzyvaTelemetry.Supervisor,
       service_name: "my_app",
       promex_module: MyApp.PromEx,
       use_file_logging: true}
  """

  use GenServer
  require Logger

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    {reporter_module, reporter_opts} = select_reporter(opts, service_name)

    # Store reporter options in process dictionary for the reporter to access
    Process.put(:tower_reporter_opts, reporter_opts)

    # Configure Tower via application environment.
    # Tower v0.8 expects a list of reporter modules, not keyword lists.
    Application.put_env(:tower, :reporters, [reporter_module])

    attach_tower(service_name, reporter_module, reporter_opts)
  end

  # Pick a reporter: explicit file logging, then explicit Loki URL, then the
  # LOKI_URL env var, falling back to file logging.
  defp select_reporter(opts, service_name) do
    cond do
      Keyword.get(opts, :use_file_logging, false) ->
        file_reporter(service_name)

      Keyword.get(opts, :loki_url) ->
        loki_reporter(service_name, Keyword.get(opts, :loki_url))

      true ->
        default_reporter(service_name)
    end
  end

  defp default_reporter(service_name) do
    case System.get_env("LOKI_URL") do
      nil -> file_reporter(service_name)
      env_loki_url -> loki_reporter(service_name, env_loki_url)
    end
  end

  defp file_reporter(service_name) do
    {ZyzyvaTelemetry.Reporters.StructuredFile,
     service_name: service_name, log_path: "/var/log/#{service_name}/errors.json"}
  end

  defp loki_reporter(service_name, loki_url) do
    {ZyzyvaTelemetry.Reporters.Loki, service_name: service_name, loki_url: loki_url}
  end

  defp attach_tower(service_name, reporter_module, reporter_opts) do
    case Tower.attach() do
      :ok ->
        Logger.info(
          "Tower error tracking configured for #{service_name} with #{inspect(reporter_module)}"
        )

        {:ok, %{service_name: service_name, reporter: reporter_module, opts: reporter_opts}}

      {:error, reason} ->
        Logger.warning("Tower attachment failed: #{inspect(reason)}")
        # Continue without Tower - don't crash the app
        {:ok,
         %{
           service_name: service_name,
           reporter: reporter_module,
           opts: reporter_opts,
           tower_attached: false
         }}
    end
  end
end
