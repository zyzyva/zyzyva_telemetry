defmodule ZyzyvaTelemetry.Plugs.AcquisitionTrackerTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ZyzyvaTelemetry.Acquisition
  alias ZyzyvaTelemetry.Plugs.AcquisitionTracker

  @session_opts Plug.Session.init(
                  store: :cookie,
                  key: "_test_session",
                  signing_salt: "test_salt_1234567890",
                  encryption_salt: "test_salt_1234567890"
                )

  setup do
    Acquisition.clear()
    :ok
  end

  defp build_conn_with_session(method, path, referer \\ nil) do
    conn =
      conn(method, path)
      |> Map.put(:secret_key_base, String.duplicate("a", 64))
      |> Plug.Session.call(@session_opts)
      |> fetch_session()

    case referer do
      nil -> conn
      value -> put_req_header(conn, "referer", value)
    end
  end

  test "captures first-touch acquisition on initial request" do
    conn =
      build_conn_with_session(:get, "/services/openclaw-setup?utm_source=linkedin", nil)
      |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    acquisition = get_session(conn, "acquisition")
    assert acquisition.source == :social_linkedin
    assert acquisition.utm_source == "linkedin"
    assert acquisition.landing_path == "/services/openclaw-setup"
    assert Acquisition.get() == acquisition
  end

  test "does not overwrite existing session acquisition on subsequent request" do
    first =
      build_conn_with_session(
        :get,
        "/services/openclaw-setup?utm_source=gbp",
        nil
      )
      |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    first_acquisition = get_session(first, "acquisition")
    assert first_acquisition.source == :gbp

    # Second request simulates the same session (existing first-touch stored)
    # returning from a LinkedIn click — first-touch should win.
    second =
      build_conn_with_session(:get, "/about", "https://www.linkedin.com/")
      |> put_session("acquisition", first_acquisition)
      |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    second_acquisition = get_session(second, "acquisition")
    assert second_acquisition == first_acquisition
    assert second_acquisition.source == :gbp
  end

  test "classifies a direct hit with no referer and no utms as :direct" do
    conn =
      build_conn_with_session(:get, "/")
      |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    acquisition = get_session(conn, "acquisition")
    assert acquisition.source == :direct
    assert acquisition.referer == nil
  end

  test "captures referer when no UTMs present" do
    conn =
      build_conn_with_session(:get, "/blog", "https://www.google.com/search?q=openclaw")
      |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    acquisition = get_session(conn, "acquisition")
    assert acquisition.source == :search_google
    assert acquisition.referer == "https://www.google.com/search"
  end

  test "refresh_on_utm: true overwrites first-touch when new UTMs arrive" do
    opts = AcquisitionTracker.init(refresh_on_utm: true)

    first =
      build_conn_with_session(:get, "/?utm_source=gbp")
      |> AcquisitionTracker.call(opts)

    first_acquisition = get_session(first, "acquisition")
    assert first_acquisition.source == :gbp

    second =
      build_conn_with_session(:get, "/blog?utm_source=linkedin&utm_campaign=launch")
      |> put_session("acquisition", first_acquisition)
      |> AcquisitionTracker.call(opts)

    assert get_session(second, "acquisition").source == :social_linkedin
    assert get_session(second, "acquisition").utm_campaign == "launch"
  end

  test "sets acquisition on the process dictionary for downstream consumers" do
    assert Acquisition.get() == nil

    build_conn_with_session(:get, "/?utm_source=gbp")
    |> AcquisitionTracker.call(AcquisitionTracker.init([]))

    assert Acquisition.get().source == :gbp
  end

  test "custom session_key option stores under the configured key" do
    opts = AcquisitionTracker.init(session_key: "source_attribution")

    conn =
      build_conn_with_session(:get, "/?utm_source=linkedin")
      |> AcquisitionTracker.call(opts)

    assert get_session(conn, "source_attribution").source == :social_linkedin
    assert get_session(conn, "acquisition") == nil
  end

  describe "geo + device enrichment" do
    test "extracts Cloudflare geo headers into acquisition" do
      conn =
        build_conn_with_session(:get, "/")
        |> put_req_header("cf-connecting-ip", "203.0.113.42")
        |> put_req_header("cf-ipcountry", "US")
        |> put_req_header("cf-region-code", "TN")
        |> put_req_header("cf-ipcity", "Elizabethton")
        |> put_req_header("cf-postal-code", "37643")
        |> put_req_header("cf-timezone", "America/New_York")
        |> put_req_header("user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)")
        |> AcquisitionTracker.call(AcquisitionTracker.init([]))

      acq = get_session(conn, "acquisition")
      assert acq.country == "US"
      assert acq.region == "TN"
      assert acq.city == "Elizabethton"
      assert acq.postal_code == "37643"
      assert acq.timezone == "America/New_York"
      assert acq.ip == "203.0.113.42"
      assert acq.user_agent =~ "iPhone"
      assert acq.device_type == :mobile
    end

    test "drops CF sentinel country codes XX and T1" do
      conn =
        build_conn_with_session(:get, "/")
        |> put_req_header("cf-ipcountry", "XX")
        |> AcquisitionTracker.call(AcquisitionTracker.init([]))

      assert get_session(conn, "acquisition").country == nil
    end

    test "classifies device types from user-agent" do
      ua_types = [
        {"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)", :mobile},
        {"Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)", :tablet},
        {"Mozilla/5.0 (Linux; Android 14; Pixel 8) Mobile Safari/537.36", :mobile},
        {"Mozilla/5.0 (Linux; Android 14; SM-T870) Safari/537.36", :tablet},
        {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", :desktop},
        {"Googlebot/2.1 (+http://www.google.com/bot.html)", :bot},
        {"curl/8.1.0", :bot}
      ]

      for {ua, expected} <- ua_types do
        conn =
          build_conn_with_session(:get, "/")
          |> put_req_header("user-agent", ua)
          |> AcquisitionTracker.call(AcquisitionTracker.init([]))

        acq = get_session(conn, "acquisition")

        assert acq.device_type == expected,
               "#{ua} => expected #{expected}, got #{acq.device_type}"
      end
    end

    test "falls back to x-forwarded-for when cf-connecting-ip absent" do
      conn =
        build_conn_with_session(:get, "/")
        |> put_req_header("x-forwarded-for", "198.51.100.7, 10.0.0.1")
        |> AcquisitionTracker.call(AcquisitionTracker.init([]))

      assert get_session(conn, "acquisition").ip == "198.51.100.7"
    end

    test "enrichment fields are nil when headers absent" do
      conn =
        build_conn_with_session(:get, "/")
        |> AcquisitionTracker.call(AcquisitionTracker.init([]))

      acq = get_session(conn, "acquisition")
      assert acq.country == nil
      assert acq.city == nil
      assert acq.device_type == nil
    end
  end
end
