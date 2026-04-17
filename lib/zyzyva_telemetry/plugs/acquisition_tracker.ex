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
    referer =
      case get_req_header(conn, "referer") do
        [value | _] -> value
        _ -> nil
      end

    Acquisition.build(referer, conn.query_params, conn.request_path)
  end

  defp utm_present?(params) when is_map(params) do
    Enum.any?(
      ~w(utm_source utm_medium utm_campaign utm_content utm_term),
      fn key -> case Map.get(params, key) do
        nil -> false
        "" -> false
        _ -> true
      end end
    )
  end

  defp utm_present?(_), do: false
end
