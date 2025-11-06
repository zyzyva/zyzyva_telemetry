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

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)
    use_file_logging = Keyword.get(opts, :use_file_logging, false)
    loki_url = Keyword.get(opts, :loki_url)

    # Determine which reporter to use
    {reporter_module, reporter_opts} =
      cond do
        # If file logging explicitly requested, use file reporter
        use_file_logging ->
          {ZyzyvaTelemetry.Reporters.StructuredFile,
           service_name: service_name, log_path: "/var/log/#{service_name}/errors.json"}

        # If Loki URL provided, use HTTP push (recommended)
        loki_url ->
          {ZyzyvaTelemetry.Reporters.Loki, service_name: service_name, loki_url: loki_url}

        # Default: try to get Loki URL from environment, fallback to file
        true ->
          case System.get_env("LOKI_URL") do
            nil ->
              {ZyzyvaTelemetry.Reporters.StructuredFile,
               service_name: service_name, log_path: "/var/log/#{service_name}/errors.json"}

            env_loki_url ->
              {ZyzyvaTelemetry.Reporters.Loki, service_name: service_name, loki_url: env_loki_url}
          end
      end

    # Store reporter options in process dictionary for the reporter to access
    Process.put(:tower_reporter_opts, reporter_opts)

    # Configure Tower with the reporter module
    # Tower v0.8 expects a list of reporter modules, not keyword lists
    reporters = [reporter_module]

    # Configure Tower via application environment
    Application.put_env(:tower, :reporters, reporters)

    # Attach Tower to the logger
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
