defmodule ZyzyvaTelemetry.EventsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.{Acquisition, Correlation, Events}

  setup do
    Acquisition.clear()
    Correlation.clear()
    prev = Application.get_env(:zyzyva_telemetry, :service_name)
    Application.put_env(:zyzyva_telemetry, :service_name, "test_app")

    on_exit(fn ->
      Acquisition.clear()
      Correlation.clear()

      if prev do
        Application.put_env(:zyzyva_telemetry, :service_name, prev)
      else
        Application.delete_env(:zyzyva_telemetry, :service_name)
      end
    end)

    :ok
  end

  describe "track_pageview/2" do
    test "emits telemetry with bounded fields only" do
      id = attach_capture([:zyzyva_telemetry, :funnel, :pageview])

      capture_log(fn -> Events.track_pageview("home") end)

      assert_receive {_event, %{count: 1}, metadata}
      assert metadata == %{service: "test_app", page_type: "home", source: "unknown"}

      :telemetry.detach(id)
    end

    test "pulls source from current Acquisition" do
      acq = Acquisition.build("https://www.linkedin.com/feed", %{}, "/")
      Acquisition.set(acq)

      id = attach_capture([:zyzyva_telemetry, :funnel, :pageview])
      capture_log(fn -> Events.track_pageview("home") end)

      assert_receive {_event, _, %{source: "social_linkedin"}}
      :telemetry.detach(id)
    end

    test "caller metadata is excluded from telemetry tags" do
      id = attach_capture([:zyzyva_telemetry, :funnel, :pageview])

      capture_log(fn ->
        Events.track_pageview("blog_post", %{slug: "my-first-post"})
      end)

      assert_receive {_event, _, metadata}
      refute Map.has_key?(metadata, :slug)
      assert metadata.page_type == "blog_post"
      :telemetry.detach(id)
    end

    test "emits a Logger.info line with the page_type in the message" do
      log = capture_log(fn -> Events.track_pageview("home") end)
      assert log =~ "pageview: home"
    end

    test "passes full UTM set to Loki via :event_fields metadata" do
      {:ok, _pid} =
        ZyzyvaTelemetry.LokiLogger.start_link(
          loki_url: nil,
          service_name: "test_app",
          flush_interval: 60_000,
          min_level: :info
        )

      acq =
        Acquisition.build(
          "https://example.com/some-ref",
          %{
            "utm_source" => "test_claude",
            "utm_medium" => "cpc",
            "utm_campaign" => "launch_apr",
            "utm_content" => "hero-a",
            "utm_term" => "openclaw"
          },
          "/landing"
        )

      Acquisition.set(acq)

      capture_log(fn ->
        Events.track_pageview("home")
        Process.sleep(50)
      end)

      state = :sys.get_state(ZyzyvaTelemetry.LokiLogger)
      assert state.buffer_size >= 1
      [entry | _] = state.buffer
      log_line = entry.log_line

      assert log_line["utm_source"] == "test_claude"
      assert log_line["utm_medium"] == "cpc"
      assert log_line["utm_campaign"] == "launch_apr"
      assert log_line["utm_content"] == "hero-a"
      assert log_line["utm_term"] == "openclaw"
      assert log_line["landing_path"] == "/landing"
      assert log_line["referer"] == "https://example.com/some-ref"
    end
  end

  describe "track_funnel_step/3" do
    test "emits telemetry with funnel + step tags" do
      id = attach_capture([:zyzyva_telemetry, :funnel, :step])

      capture_log(fn -> Events.track_funnel_step("consultant", "gate_unlocked") end)

      assert_receive {_event, %{count: 1}, metadata}
      assert metadata.funnel == "consultant"
      assert metadata.step == "gate_unlocked"
      assert metadata.service == "test_app"
      assert metadata.source == "unknown"
      :telemetry.detach(id)
    end

    test "message includes funnel and step" do
      log = capture_log(fn -> Events.track_funnel_step("consultant", "gate_unlocked") end)
      assert log =~ "funnel_step: consultant/gate_unlocked"
    end
  end

  describe "track_conversion/2" do
    test "emits telemetry with conversion_type tag" do
      id = attach_capture([:zyzyva_telemetry, :funnel, :conversion])

      capture_log(fn -> Events.track_conversion("contact_form") end)

      assert_receive {_event, %{count: 1}, metadata}
      assert metadata.conversion_type == "contact_form"
      assert metadata.service == "test_app"
      :telemetry.detach(id)
    end

    test "message includes conversion_type" do
      log = capture_log(fn -> Events.track_conversion("contact_form") end)
      assert log =~ "conversion: contact_form"
    end
  end

  describe "source fallback" do
    test "source is 'unknown' when no Acquisition set" do
      id = attach_capture([:zyzyva_telemetry, :funnel, :pageview])
      capture_log(fn -> Events.track_pageview("home") end)

      assert_receive {_event, _, %{source: "unknown"}}
      :telemetry.detach(id)
    end
  end

  describe "service fallback" do
    test "service is 'unknown' when app config is missing" do
      Application.delete_env(:zyzyva_telemetry, :service_name)

      id = attach_capture([:zyzyva_telemetry, :funnel, :pageview])
      capture_log(fn -> Events.track_pageview("home") end)

      assert_receive {_event, _, %{service: "unknown"}}
      :telemetry.detach(id)
    end
  end

  # --- helpers ---

  defp attach_capture(event) do
    id = {:test_capture, :erlang.unique_integer()}
    test_pid = self()

    :telemetry.attach(
      id,
      event,
      fn e, m, md, _ -> send(test_pid, {e, m, md}) end,
      nil
    )

    id
  end

end
