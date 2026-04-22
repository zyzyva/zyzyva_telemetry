defmodule ZyzyvaTelemetry.Acquisition do
  @moduledoc """
  First-touch acquisition tracking: classify how a visitor arrived, capture
  UTM parameters, and propagate the metadata across the request lifecycle.

  The visitor's *first* referrer and UTM params are what matter for attribution.
  A buyer may click a GBP link, return direct tomorrow, and convert next week —
  GBP should still get credit. `ZyzyvaTelemetry.Plugs.AcquisitionTracker` persists
  first-touch on the session (and optionally a long-lived cookie) so downstream
  visits don't overwrite it.

  ## Source buckets (low cardinality, stable for Prometheus tags)

    * `:direct` — no referer, no UTM
    * `:search_google`, `:search_bing`, `:search_ddg`, `:search_other`
    * `:social_linkedin`, `:social_x`, `:social_facebook`, `:social_reddit`,
      `:social_youtube`, `:social_instagram`, `:social_other`
    * `:email` — mail clients or `utm_medium=email`
    * `:gbp` — Google Business Profile (utm_source or maps.google referer)
    * `:referral_other` — any other HTTP referer

  ## Acquisition map

      %{
        source: :search_google,
        referer: "https://www.google.com/",
        landing_path: "/services/openclaw-setup",
        utm_source: "google",
        utm_medium: "organic",
        utm_campaign: "launch",
        utm_content: "headline-a",
        utm_term: "openclaw setup",
        country: "US",
        region: "TN",
        city: "Elizabethton",
        postal_code: "37643",
        timezone: "America/New_York",
        ip: "203.0.113.42",
        user_agent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0...)",
        device_type: :mobile,
        first_touch_at: ~U[2026-04-17 14:32:00Z]
      }

  All UTM, geo, and device fields are `nil` when absent. Cardinality for
  `source` is fixed; do not tag Prometheus counters with the raw `referer`,
  `utm_*`, `city`, `ip`, or `user_agent` fields — they belong in Loki only.
  `country` and `device_type` have bounded cardinality and are safe for Prom
  tags if you need geo/device breakdowns in PromQL.
  """

  @acquisition_key :zyzyva_telemetry_acquisition

  @type source ::
          :direct
          | :search_google
          | :search_bing
          | :search_ddg
          | :search_other
          | :social_linkedin
          | :social_x
          | :social_facebook
          | :social_reddit
          | :social_youtube
          | :social_instagram
          | :social_other
          | :email
          | :gbp
          | :referral_other

  @type device_type :: :mobile | :tablet | :desktop | :bot | :unknown

  @type t :: %{
          source: source(),
          referer: String.t() | nil,
          landing_path: String.t() | nil,
          utm_source: String.t() | nil,
          utm_medium: String.t() | nil,
          utm_campaign: String.t() | nil,
          utm_content: String.t() | nil,
          utm_term: String.t() | nil,
          country: String.t() | nil,
          region: String.t() | nil,
          city: String.t() | nil,
          postal_code: String.t() | nil,
          timezone: String.t() | nil,
          ip: String.t() | nil,
          user_agent: String.t() | nil,
          device_type: device_type() | nil,
          first_touch_at: DateTime.t()
        }

  @utm_keys ~w(utm_source utm_medium utm_campaign utm_content utm_term)
  @enrichment_keys ~w(country region city postal_code timezone ip user_agent device_type)a

  @doc """
  Build an acquisition map from a referer URL and query params.

  `params` is typically the parsed query string from the landing request.
  `landing_path` is the initial URL path the visitor hit.
  `enrichment` (optional) is a map with any of `country`, `region`, `city`,
  `postal_code`, `timezone`, `ip`, `user_agent`, `device_type` keys — typically
  extracted by `ZyzyvaTelemetry.Plugs.AcquisitionTracker` from Cloudflare
  `cf-*` headers and the `user-agent` header.
  """
  @spec build(String.t() | nil, map(), String.t() | nil, map(), DateTime.t()) :: t()
  def build(referer, params, landing_path, enrichment \\ %{}, now \\ DateTime.utc_now())

  def build(referer, params, landing_path, %DateTime{} = now, _) do
    # Backward-compat 4-arg form: (referer, params, landing_path, now)
    build(referer, params, landing_path, %{}, now)
  end

  def build(referer, params, landing_path, enrichment, now) when is_map(enrichment) do
    utms = extract_utms(params)
    source = classify(referer, utms)

    base = %{
      source: source,
      referer: normalize_referer(referer),
      landing_path: landing_path,
      utm_source: utms["utm_source"],
      utm_medium: utms["utm_medium"],
      utm_campaign: utms["utm_campaign"],
      utm_content: utms["utm_content"],
      utm_term: utms["utm_term"],
      first_touch_at: now
    }

    Enum.reduce(@enrichment_keys, base, fn key, acc ->
      Map.put(acc, key, Map.get(enrichment, key))
    end)
  end

  @doc """
  Classify a source bucket from a referer URL and UTM params.

  UTM params take priority when present. `utm_source` of `"gbp"`,
  `"google_business"`, or `"google_business_profile"` maps to `:gbp`.
  `utm_medium=email` maps to `:email` regardless of source. Named social
  UTM sources (`linkedin`, `twitter`, `x`, `facebook`, `reddit`) map to
  their social buckets.

  Without UTMs, the referer host is used.
  """
  @spec classify(String.t() | nil, map()) :: source()
  def classify(referer, utms \\ %{})

  def classify(referer, utms) when is_map(utms) do
    cond do
      classify_utm_source(utms) != :unknown -> classify_utm_source(utms)
      is_binary(referer) and referer != "" -> classify_referer(referer)
      true -> :direct
    end
  end

  @doc """
  Classify a source from a referer URL alone. Returns `:direct` if nil/empty.
  """
  @spec classify_referer(String.t() | nil) :: source()
  def classify_referer(nil), do: :direct
  def classify_referer(""), do: :direct

  def classify_referer(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: nil} -> :direct
      %URI{host: host} -> host |> String.downcase() |> classify_host()
    end
  end

  # --- Private: host-based classification ---

  defp classify_host(host) do
    cond do
      # Mail clients FIRST — mail.google.com must beat the generic google. match
      String.contains?(host, "mail.google.") ->
        :email

      String.contains?(host, "mail.yahoo.") ->
        :email

      String.contains?(host, "outlook.") ->
        :email

      String.contains?(host, "proton.me") ->
        :email

      String.contains?(host, "fastmail.") ->
        :email

      # Google Business Profile / Maps — must beat the generic google. match
      String.contains?(host, "maps.google.") ->
        :gbp

      String.contains?(host, "business.google.") ->
        :gbp

      # Search engines
      String.contains?(host, "google.") ->
        :search_google

      String.contains?(host, "bing.") ->
        :search_bing

      String.contains?(host, "duckduckgo.") ->
        :search_ddg

      String.contains?(host, "yahoo.") ->
        :search_other

      String.contains?(host, "ecosia.") ->
        :search_other

      String.contains?(host, "kagi.") ->
        :search_other

      String.contains?(host, "brave.") ->
        :search_other

      # Social
      String.contains?(host, "linkedin.") ->
        :social_linkedin

      host == "t.co" or String.contains?(host, "twitter.") or String.contains?(host, "x.com") ->
        :social_x

      String.contains?(host, "facebook.") or host == "l.facebook.com" or host == "lm.facebook.com" ->
        :social_facebook

      String.contains?(host, "reddit.") or host == "out.reddit.com" ->
        :social_reddit

      String.contains?(host, "youtube.") or host == "youtu.be" ->
        :social_youtube

      String.contains?(host, "instagram.") ->
        :social_instagram

      String.contains?(host, "threads.net") ->
        :social_other

      String.contains?(host, "tiktok.") ->
        :social_other

      String.contains?(host, "bsky.") or String.contains?(host, "bluesky.") ->
        :social_other

      String.contains?(host, "mastodon.") ->
        :social_other

      true ->
        :referral_other
    end
  end

  # --- Private: UTM-based classification ---

  defp classify_utm_source(utms) do
    cond do
      utms["utm_medium"] == "email" ->
        :email

      (utm = utms["utm_source"]) && utm != "" ->
        utm_to_bucket(String.downcase(utm))

      true ->
        :unknown
    end
  end

  defp utm_to_bucket("gbp"), do: :gbp
  defp utm_to_bucket("google_business"), do: :gbp
  defp utm_to_bucket("google_business_profile"), do: :gbp
  defp utm_to_bucket("google-business-profile"), do: :gbp
  defp utm_to_bucket("google"), do: :search_google
  defp utm_to_bucket("bing"), do: :search_bing
  defp utm_to_bucket("duckduckgo"), do: :search_ddg
  defp utm_to_bucket("ddg"), do: :search_ddg
  defp utm_to_bucket("linkedin"), do: :social_linkedin
  defp utm_to_bucket("x"), do: :social_x
  defp utm_to_bucket("twitter"), do: :social_x
  defp utm_to_bucket("facebook"), do: :social_facebook
  defp utm_to_bucket("fb"), do: :social_facebook
  defp utm_to_bucket("instagram"), do: :social_instagram
  defp utm_to_bucket("ig"), do: :social_instagram
  defp utm_to_bucket("reddit"), do: :social_reddit
  defp utm_to_bucket("youtube"), do: :social_youtube
  defp utm_to_bucket("newsletter"), do: :email
  defp utm_to_bucket("email"), do: :email
  defp utm_to_bucket(_), do: :referral_other

  # --- Private: parsing helpers ---

  defp extract_utms(params) when is_map(params) do
    Enum.reduce(@utm_keys, %{}, fn key, acc ->
      case fetch_param(params, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp extract_utms(_), do: %{}

  defp fetch_param(params, key) do
    case Map.get(params, key) do
      nil -> Map.get(params, String.to_atom(key))
      value -> value
    end
  end

  defp normalize_referer(nil), do: nil
  defp normalize_referer(""), do: nil

  defp normalize_referer(url) when is_binary(url) do
    # Strip query strings from stored referer to reduce cardinality and
    # avoid leaking any sensitive query params a competitor/source may embed.
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: path} when is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, path: path})

      _ ->
        nil
    end
  end

  # --- Process dictionary propagation ---

  @doc """
  Stores the acquisition map on the current process so `TelemetryHelper`-style
  emitters can read it without threading it through every function call.
  """
  @spec set(t()) :: :ok
  def set(acquisition) when is_map(acquisition) do
    Process.put(@acquisition_key, acquisition)
    :ok
  end

  @doc """
  Returns the current acquisition map, or `nil` if none set.
  """
  @spec get() :: t() | nil
  def get do
    Process.get(@acquisition_key)
  end

  @doc "Alias for `get/0`."
  @spec current() :: t() | nil
  def current, do: get()

  @doc "Clears the acquisition map from the process dictionary."
  @spec clear() :: :ok
  def clear do
    Process.delete(@acquisition_key)
    :ok
  end

  @doc """
  Merges the current acquisition `source` (and optionally `utm_campaign`) into
  a telemetry metadata map. Safe to call when no acquisition is set — returns
  the input unchanged.

  Only `source` is merged by default since it's the only field with bounded
  cardinality appropriate for Prometheus tags. UTM fields should be persisted
  on DB records (conversions) rather than emitted as telemetry tags.
  """
  @spec propagate(map()) :: map()
  def propagate(metadata) when is_map(metadata) do
    case get() do
      nil -> metadata
      %{source: source} -> Map.put_new(metadata, :source, source)
    end
  end
end
