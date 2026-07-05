defmodule ZyzyvaTelemetry.PromEx do
  @moduledoc """
  Pre-configured PromEx setup with ecosystem defaults.

  Usage:

      defmodule MyApp.PromEx do
        use ZyzyvaTelemetry.PromEx,
          otp_app: :my_app,
          service_name: "my_app",
          router: MyAppWeb.Router,
          repos: [MyApp.Repo],
          additional_plugins: [MyApp.CustomPlugin]
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

        ZyzyvaTelemetry.PromEx.build_plugins(
          base_plugins,
          unquote(opts[:repos]),
          unquote(opts[:broadway_pipelines]),
          unquote(opts[:additional_plugins])
        )
      end

      @impl true
      def dashboard_assigns do
        [datasource_id: "prometheus", default_selected_interval: "30s"]
      end
    end
  end

  @doc false
  # Assemble the full plugin list from the base plugins plus the opt-in ones,
  # preserving the historical ordering. Called from the generated `plugins/0`.
  @spec build_plugins(list(), term(), term(), term()) :: list()
  def build_plugins(base_plugins, repos, broadway_pipelines, additional) do
    base_plugins ++
      ecto_plugins(repos) ++
      enhanced_ecto_plugins(repos) ++
      broadway_plugins(broadway_pipelines) ++
      default_plugins() ++
      additional_plugins(additional)
  end

  defp ecto_plugins(nil), do: []
  defp ecto_plugins([]), do: []
  defp ecto_plugins(repos), do: [{PromEx.Plugins.Ecto, repos: repos}]

  defp enhanced_ecto_plugins(nil), do: []
  defp enhanced_ecto_plugins([]), do: []
  defp enhanced_ecto_plugins(repos), do: [{ZyzyvaTelemetry.Plugins.EnhancedEcto, repos: repos}]

  defp broadway_plugins(nil), do: []
  defp broadway_plugins([]), do: []
  defp broadway_plugins(pipelines), do: [{PromEx.Plugins.Broadway, pipelines: pipelines}]

  # Always-on opt-in plugins (each gates itself via config at runtime).
  defp default_plugins do
    [
      ZyzyvaTelemetry.Plugins.Finch,
      ZyzyvaTelemetry.Plugins.EnhancedPhoenix,
      ZyzyvaTelemetry.Plugins.EnhancedLiveView,
      ZyzyvaTelemetry.Plugins.AiTokenUsage
    ]
  end

  defp additional_plugins(nil), do: []
  defp additional_plugins([]), do: []
  defp additional_plugins(plugins) when is_list(plugins), do: plugins
  defp additional_plugins(plugin), do: [plugin]
end
