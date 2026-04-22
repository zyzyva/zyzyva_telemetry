defmodule ZyzyvaTelemetry.Plugins.FunnelMetricsTest do
  use ExUnit.Case, async: true

  alias ZyzyvaTelemetry.Plugins.FunnelMetrics

  defp all_metrics do
    FunnelMetrics.event_metrics([])
    |> Enum.flat_map(fn
      %{metrics: metrics} -> metrics
      metric -> [metric]
    end)
  end

  describe "event_metrics/1" do
    test "exposes the three funnel counters" do
      names = Enum.map(all_metrics(), & &1.name)

      assert [:zyzyva, :funnel, :pageviews, :total] in names
      assert [:zyzyva, :funnel, :steps, :total] in names
      assert [:zyzyva, :funnel, :conversions, :total] in names
    end

    test "pageview counter subscribes to the library-owned pageview event" do
      pageview =
        Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :pageviews, :total]))

      assert pageview.event_name == [:zyzyva_telemetry, :funnel, :pageview]
      assert pageview.tags == [:service, :page_type, :source]
    end

    test "step counter uses bounded funnel/step/source tags" do
      step = Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :steps, :total]))

      assert step.event_name == [:zyzyva_telemetry, :funnel, :step]
      assert step.tags == [:service, :funnel, :step, :source]
    end

    test "conversion counter uses bounded conversion_type/source tags" do
      conv = Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :conversions, :total]))

      assert conv.event_name == [:zyzyva_telemetry, :funnel, :conversion]
      assert conv.tags == [:service, :conversion_type, :source]
    end
  end

  describe "tag_values coerce metadata" do
    test "pageview tags substitute 'unknown' for missing keys" do
      pageview =
        Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :pageviews, :total]))

      tags = pageview.tag_values.(%{})

      assert tags == %{service: "unknown", page_type: "unknown", source: "unknown"}
    end

    test "pageview tags stringify atoms" do
      pageview =
        Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :pageviews, :total]))

      tags = pageview.tag_values.(%{service: :my_app, page_type: "home", source: :direct})

      assert tags == %{service: "my_app", page_type: "home", source: "direct"}
    end

    test "step tags include funnel + step + source" do
      step = Enum.find(all_metrics(), &(&1.name == [:zyzyva, :funnel, :steps, :total]))

      tags =
        step.tag_values.(%{
          service: "app",
          funnel: "consultant",
          step: "gate_unlocked",
          source: "direct"
        })

      assert tags == %{
               service: "app",
               funnel: "consultant",
               step: "gate_unlocked",
               source: "direct"
             }
    end
  end
end
