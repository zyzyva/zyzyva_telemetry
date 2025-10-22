defmodule ZyzyvaTelemetry.Supervisor do
  @moduledoc """
  Main supervisor that starts all observability components.

  Usage in application.ex:

      {ZyzyvaTelemetry.Supervisor,
       service_name: "my_app",
       promex_module: MyApp.PromEx,
       repo: MyApp.Repo}
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    service_name = Keyword.fetch!(opts, :service_name)

    children =
      [
        # PromEx metrics exporter (if module is provided)
        if(opts[:promex_module], do: {opts[:promex_module], opts}, else: nil),

        # Tower error tracking with v0.8 compatibility
        {ZyzyvaTelemetry.ErrorTracking, opts},

        # Correlation ID manager is a utility module, not a GenServer - removed from supervision tree

        # Health check registry
        {ZyzyvaTelemetry.Health.Registry, service_name: service_name}
      ]
      |> Enum.filter(&(&1 != nil))

    Supervisor.init(children, strategy: :one_for_one)
  end
end
