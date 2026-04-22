defmodule ZyzyvaTelemetry.Plugins.FunnelMetrics do
  @moduledoc """
  PromEx plugin that turns `ZyzyvaTelemetry.Events` calls into Prometheus counters.

  Attach this plugin from your app's PromEx module:

      defmodule MyApp.PromEx do
        use ZyzyvaTelemetry.PromEx,
          otp_app: :my_app,
          service_name: "my_app",
          router: MyAppWeb.Router,
          repos: [MyApp.Repo],
          additional_plugins: [ZyzyvaTelemetry.Plugins.FunnelMetrics]
      end

  It subscribes to the library-owned events emitted by `ZyzyvaTelemetry.Events`
  and exposes three counters:

    * `zyzyva_funnel_pageviews_total{service, page_type, source}`
    * `zyzyva_funnel_steps_total{service, funnel, step, source}`
    * `zyzyva_funnel_conversions_total{service, conversion_type, source}`

  ## Cardinality

  Tag values are deliberately bounded. The `Events` module does not forward
  high-cardinality fields (slug, utm_campaign, session_id, etc.) to the
  telemetry metadata, so they cannot show up here. That is by design — for
  per-slug / per-campaign analytics, query the Loki logs via LogQL instead.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :zyzyva_funnel_metrics,
        [
          counter(
            [:zyzyva, :funnel, :pageviews, :total],
            event_name: [:zyzyva_telemetry, :funnel, :pageview],
            description: "Total marketing page views, tagged by page type and source",
            tags: [:service, :page_type, :source],
            tag_values: &pageview_tags/1
          ),
          counter(
            [:zyzyva, :funnel, :steps, :total],
            event_name: [:zyzyva_telemetry, :funnel, :step],
            description: "Total funnel step events, tagged by funnel, step, and source",
            tags: [:service, :funnel, :step, :source],
            tag_values: &step_tags/1
          ),
          counter(
            [:zyzyva, :funnel, :conversions, :total],
            event_name: [:zyzyva_telemetry, :funnel, :conversion],
            description: "Total conversion events, tagged by type and source",
            tags: [:service, :conversion_type, :source],
            tag_values: &conversion_tags/1
          )
        ]
      )
    ]
  end

  @impl true
  def polling_metrics(_opts), do: []

  defp pageview_tags(metadata) do
    %{
      service: tag(metadata[:service]),
      page_type: tag(metadata[:page_type]),
      source: tag(metadata[:source])
    }
  end

  defp step_tags(metadata) do
    %{
      service: tag(metadata[:service]),
      funnel: tag(metadata[:funnel]),
      step: tag(metadata[:step]),
      source: tag(metadata[:source])
    }
  end

  defp conversion_tags(metadata) do
    %{
      service: tag(metadata[:service]),
      conversion_type: tag(metadata[:conversion_type]),
      source: tag(metadata[:source])
    }
  end

  defp tag(nil), do: "unknown"
  defp tag(value) when is_binary(value), do: value
  defp tag(value) when is_atom(value), do: Atom.to_string(value)
  defp tag(value), do: to_string(value)
end
