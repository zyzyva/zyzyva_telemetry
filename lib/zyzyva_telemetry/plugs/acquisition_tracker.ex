defmodule ZyzyvaTelemetry.Plugs.AcquisitionTracker do
  @moduledoc """
  Plug that captures first-touch acquisition data for each visitor session.

  On the first request of a session (no acquisition already stored), reads the
  `Referer` header and any `utm_*` query params, classifies them via
  `ZyzyvaTelemetry.Acquisition`, and stashes the resulting map on the session.

  On subsequent requests in the same session, the stored first-touch wins —
  later referrers do NOT overwrite it. This is deliberate: a buyer who first
  arrives via a GBP link and later returns direct should still be attributed
  to GBP.

  The plug also writes the acquisition map to the process dictionary so
  telemetry emitters (and any code within the same request) can read it
  without threading it through function calls.

  ## Options

    * `:session_key` — session key to persist first-touch under. Defaults to
      `"acquisition"`.
    * `:refresh_on_utm` — when `true`, a request that arrives with new UTM
      params will overwrite the first-touch map. Useful for campaign-level
      attribution where the latest campaign click is what matters. Defaults
      to `false` (pure first-touch).

  ## Usage

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug ZyzyvaTelemetry.Plugs.AcquisitionTracker
        # ...
      end

  Must run after `:fetch_session`.

  ## LiveView integration

  Read the acquisition map from session in `mount/3`:

      def mount(_params, session, socket) do
        acquisition = session["acquisition"]
        # assign to socket, persist to DB on conversion, etc.
      end

  For telemetry emitted from a LiveView process, manually set the acquisition
  on the LV process (once, in `mount/3`):

      ZyzyvaTelemetry.Acquisition.set(acquisition)
  """

  import Plug.Conn

  alias ZyzyvaTelemetry.Acquisition

  @default_session_key "acquisition"

  def init(opts) do
    %{
      session_key: Keyword.get(opts, :session_key, @default_session_key),
      refresh_on_utm: Keyword.get(opts, :refresh_on_utm, false)
    }
  end

  def call(conn, %{session_key: session_key, refresh_on_utm: refresh_on_utm}) do
    conn = fetch_query_params(conn)
    existing = get_session(conn, session_key)
    has_new_utms? = utm_present?(conn.query_params)

    acquisition =
      cond do
        existing && !(refresh_on_utm and has_new_utms?) ->
          existing

        true ->
          build_from_conn(conn)
      end

    Acquisition.set(acquisition)

    if acquisition != existing do
      put_session(conn, session_key, acquisition)
    else
      conn
    end
  end

  defp build_from_conn(conn) do
    referer = first_header(conn, "referer")
    enrichment = extract_enrichment(conn)

    Acquisition.build(referer, conn.query_params, conn.request_path, enrichment)
  end

  defp extract_enrichment(conn) do
    user_agent = first_header(conn, "user-agent")

    %{
      country: cf_header(conn, "cf-ipcountry"),
      region: cf_header(conn, "cf-region-code") || cf_header(conn, "cf-region"),
      city: cf_header(conn, "cf-ipcity"),
      postal_code: cf_header(conn, "cf-postal-code"),
      timezone: cf_header(conn, "cf-timezone"),
      ip: cf_header(conn, "cf-connecting-ip") || client_ip_fallback(conn),
      user_agent: user_agent,
      device_type: classify_device(user_agent)
    }
  end

  # CF sets country as literal "XX" when it cannot determine it.
  # T1 means Tor exit node. Drop both — they're noise in Loki.
  defp cf_header(conn, name) do
    case first_header(conn, name) do
      nil -> nil
      "" -> nil
      "XX" -> nil
      "T1" -> nil
      value -> value
    end
  end

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp client_ip_fallback(conn) do
    case first_header(conn, "x-forwarded-for") do
      nil ->
        conn.remote_ip && conn.remote_ip |> :inet.ntoa() |> to_string()

      xff ->
        xff |> String.split(",") |> List.first() |> String.trim()
    end
  end

  # Cheap UA classification — no external deps. 95% accurate for our purposes;
  # add `ua_inspector` later if you need browser/OS breakdowns.
  defp classify_device(nil), do: nil
  defp classify_device(""), do: nil

  defp classify_device(ua) when is_binary(ua) do
    ua = String.downcase(ua)

    cond do
      bot?(ua) -> :bot
      tablet?(ua) -> :tablet
      mobile?(ua) -> :mobile
      true -> :desktop
    end
  end

  defp bot?(ua),
    do:
      String.contains?(ua, "bot") or
        String.contains?(ua, "crawler") or
        String.contains?(ua, "spider") or
        String.contains?(ua, "headlesschrome") or
        String.contains?(ua, "lighthouse") or
        String.contains?(ua, "slurp") or
        String.contains?(ua, "curl/") or
        String.contains?(ua, "wget/")

  defp tablet?(ua),
    do:
      String.contains?(ua, "ipad") or
        (String.contains?(ua, "android") and not String.contains?(ua, "mobile"))

  defp mobile?(ua),
    do:
      String.contains?(ua, "mobile") or
        String.contains?(ua, "iphone") or
        String.contains?(ua, "ipod") or
        String.contains?(ua, "android") or
        String.contains?(ua, "windows phone") or
        String.contains?(ua, "blackberry")

  defp utm_present?(params) when is_map(params) do
    Enum.any?(
      ~w(utm_source utm_medium utm_campaign utm_content utm_term),
      fn key ->
        case Map.get(params, key) do
          nil -> false
          "" -> false
          _ -> true
        end
      end
    )
  end

  defp utm_present?(_), do: false
end
