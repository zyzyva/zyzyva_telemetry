defmodule ZyzyvaTelemetry.Events do
  @moduledoc """
  Opinionated attribution + funnel tracking API for the Zyzyva ecosystem.

  Three call sites cover end-to-end marketing attribution:

    * `track_pageview/2` — a marketing-relevant page was viewed
    * `track_funnel_step/3` — an intermediate conversion event (e.g. gate unlocked,
      template selected)
    * `track_conversion/2` — a money event (contact form submitted, booking made,
      trial started)

  Every call emits two artifacts:

    1. A `:telemetry` event with **bounded** metadata fields suitable for
       Prometheus tagging. Pick these up with
       `ZyzyvaTelemetry.Plugins.FunnelMetrics` in your PromEx module.

    2. A `Logger.info/2` call with the **full** metadata (including high-cardinality
       fields like `slug`, `utm_campaign`, `session_id`) under the `:event_fields`
       log metadata key. `ZyzyvaTelemetry.LokiLogger` promotes those fields to
       top-level JSON, enabling LogQL queries like:

           {service="hunter_dev"} | json | event_type="pageview" | page_type="blog_post"

  ## Auto-injected fields

  Every emitted event carries:

    * `service` — the OTP app name, from config `:zyzyva_telemetry, :service_name`
    * `event_type` — one of `"pageview" | "funnel_step" | "conversion"`
    * `source` — the low-cardinality acquisition bucket, via
      `ZyzyvaTelemetry.Acquisition.current/0` (defaults to `"unknown"` if no
      acquisition plug ran on this request)
    * `correlation_id` — from `ZyzyvaTelemetry.Correlation.current/0` when set
    * `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`,
      `landing_path`, `referer` — from `Acquisition.current/0` when set.
      These ride only to Loki; Prom tags use the bucketed `source` instead.
    * `timestamp` — UTC ISO8601

  ## Prometheus cardinality contract

  The PromEx plugin tags counters with ONLY:

    * `service`, `source`, and the event-specific discriminator
      (`page_type`, `funnel` + `step`, or `conversion_type`)

  Any additional metadata you pass (slug, business_type, role, etc.) is ignored
  by the PromEx plugin and goes **only** to Loki. Per-slug analytics live in
  LogQL, not PromQL. This keeps the Prom series count bounded regardless of how
  many blog posts or projects you publish.

  ## Usage

      # One-time config
      config :zyzyva_telemetry, service_name: "hunter_dev"

      # Page views
      ZyzyvaTelemetry.Events.track_pageview("home")
      ZyzyvaTelemetry.Events.track_pageview("blog_post", %{slug: "my-post"})

      # Funnel intermediate steps
      ZyzyvaTelemetry.Events.track_funnel_step("consultant", "gate_unlocked")
      ZyzyvaTelemetry.Events.track_funnel_step("consultant", "template_selected",
        %{business_type: "hvac"})

      # Conversions
      ZyzyvaTelemetry.Events.track_conversion("contact_form")
      ZyzyvaTelemetry.Events.track_conversion("booking", %{value_cents: 15_000})
  """

  require Logger

  alias ZyzyvaTelemetry.{Acquisition, Correlation}

  @event_pageview [:zyzyva_telemetry, :funnel, :pageview]
  @event_funnel_step [:zyzyva_telemetry, :funnel, :step]
  @event_conversion [:zyzyva_telemetry, :funnel, :conversion]

  @doc """
  Records a marketing-relevant page view.

  `page_type` should be a stable, low-cardinality string: `"home"`, `"about"`,
  `"blog_post"`, `"landing_openclaw"`. Page-specific identifiers (blog slug,
  project slug) go in `metadata` and flow to Loki only.
  """
  @spec track_pageview(String.t(), map()) :: :ok
  def track_pageview(page_type, metadata \\ %{}) when is_binary(page_type) and is_map(metadata) do
    emit(@event_pageview, "pageview", %{page_type: page_type}, metadata)
  end

  @doc """
  Records an intermediate funnel conversion step.

  `funnel` names the overall flow (`"consultant"`, `"signup"`, `"checkout"`).
  `step` names the specific moment (`"gate_unlocked"`, `"template_selected"`).
  """
  @spec track_funnel_step(String.t(), String.t(), map()) :: :ok
  def track_funnel_step(funnel, step, metadata \\ %{})
      when is_binary(funnel) and is_binary(step) and is_map(metadata) do
    emit(@event_funnel_step, "funnel_step", %{funnel: funnel, step: step}, metadata)
  end

  @doc """
  Records a conversion — the money event you ultimately want to attribute to a
  source.

  `conversion_type` examples: `"contact_form"`, `"booking"`, `"trial_started"`,
  `"purchase"`. Attach revenue or identifying context in `metadata`
  (e.g. `%{value_cents: 15_000, plan: "pro"}`); it rides to Loki.
  """
  @spec track_conversion(String.t(), map()) :: :ok
  def track_conversion(conversion_type, metadata \\ %{})
      when is_binary(conversion_type) and is_map(metadata) do
    emit(@event_conversion, "conversion", %{conversion_type: conversion_type}, metadata)
  end

  # ----------------------------------------------------------------------------
  # Internal
  # ----------------------------------------------------------------------------

  defp emit(event_name, event_type, bounded_fields, caller_metadata) do
    service = service_name()
    source = current_source()
    utms = current_utms()

    # Bounded fields — safe for Prom tags.
    prom_metadata =
      bounded_fields
      |> Map.put(:service, service)
      |> Map.put(:source, source)

    # Full fields — everything goes to Loki. Caller metadata is merged last so
    # explicit slug/utm overrides from the caller take precedence over
    # auto-injected values.
    full_fields =
      prom_metadata
      |> Map.merge(%{
        event_type: event_type,
        correlation_id: Correlation.current(),
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })
      |> Map.merge(utms)
      |> Map.merge(caller_metadata)
      |> drop_nils()

    :telemetry.execute(event_name, %{count: 1}, prom_metadata)

    Logger.info(log_message(event_type, full_fields), event_fields: full_fields)

    :ok
  end

  defp service_name do
    Application.get_env(:zyzyva_telemetry, :service_name) || "unknown"
  end

  defp current_source do
    case Acquisition.current() do
      %{source: source} when is_atom(source) -> Atom.to_string(source)
      _ -> "unknown"
    end
  end

  defp current_utms do
    case Acquisition.current() do
      %{} = acq ->
        %{
          utm_source: acq[:utm_source],
          utm_medium: acq[:utm_medium],
          utm_campaign: acq[:utm_campaign],
          utm_content: acq[:utm_content],
          utm_term: acq[:utm_term],
          landing_path: acq[:landing_path],
          referer: acq[:referer]
        }

      _ ->
        %{}
    end
  end

  defp drop_nils(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp log_message("pageview", %{page_type: pt}), do: "pageview: #{pt}"
  defp log_message("funnel_step", %{funnel: f, step: s}), do: "funnel_step: #{f}/#{s}"
  defp log_message("conversion", %{conversion_type: c}), do: "conversion: #{c}"
  defp log_message(type, _), do: "event: #{type}"
end
