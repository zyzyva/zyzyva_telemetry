defmodule ZyzyvaTelemetry.PromEx do
  @moduledoc """
  Pre-configured PromEx setup with ecosystem defaults.

  Usage:

      defmodule MyApp.PromEx do
        use ZyzyvaTelemetry.PromEx,
          otp_app: :my_app,
          service_name: "my_app",
          router: MyAppWeb.Router,
          repos: [MyApp.Repo]
      end
  """

  defmacro __using__(opts) do
    quote do
      use PromEx, otp_app: unquote(opts[:otp_app])

      @impl true
      def plugins do
        base_plugins = [
          PromEx.Plugins.Beam,
          {PromEx.Plugins.Phoenix, router: unquote(opts[:router])},
          {ZyzyvaTelemetry.Plugins.EcosystemMetrics, service_name: unquote(opts[:service_name])}
        ]

        # Add Ecto plugin if repos are provided
        ecto_plugins =
          case unquote(opts[:repos]) do
            nil -> []
            [] -> []
            repos -> [{PromEx.Plugins.Ecto, repos: repos}]
          end

        # Add Enhanced Ecto plugin if repos are provided (opt-in via config)
        enhanced_ecto_plugins =
          case unquote(opts[:repos]) do
            nil -> []
            [] -> []
            repos -> [{ZyzyvaTelemetry.Plugins.EnhancedEcto, repos: repos}]
          end

        # Add Broadway plugin if pipelines are provided
        broadway_plugins =
          case unquote(opts[:broadway_pipelines]) do
            nil -> []
            [] -> []
            pipelines -> [{PromEx.Plugins.Broadway, pipelines: pipelines}]
          end

        # Add Finch plugin (opt-in via config)
        finch_plugins = [ZyzyvaTelemetry.Plugins.Finch]

        # Add Enhanced Phoenix plugin (opt-in via config)
        enhanced_phoenix_plugins = [ZyzyvaTelemetry.Plugins.EnhancedPhoenix]

        # Add Enhanced LiveView plugin (opt-in via config)
        enhanced_live_view_plugins = [ZyzyvaTelemetry.Plugins.EnhancedLiveView]

        # Add AI Token Usage plugin (opt-in via config)
        ai_token_usage_plugins = [ZyzyvaTelemetry.Plugins.AiTokenUsage]

        base_plugins ++
          ecto_plugins ++
          enhanced_ecto_plugins ++
          broadway_plugins ++
          finch_plugins ++
          enhanced_phoenix_plugins ++
          enhanced_live_view_plugins ++
          ai_token_usage_plugins
      end

      @impl true
      def dashboard_assigns do
        [datasource_id: "prometheus", default_selected_interval: "30s"]
      end
    end
  end
end
