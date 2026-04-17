defmodule ZyzyvaTelemetry.AcquisitionTest do
  use ExUnit.Case, async: true

  alias ZyzyvaTelemetry.Acquisition

  describe "classify_referer/1" do
    test "returns :direct for nil and empty" do
      assert Acquisition.classify_referer(nil) == :direct
      assert Acquisition.classify_referer("") == :direct
    end

    test "classifies Google search" do
      assert Acquisition.classify_referer("https://www.google.com/search?q=openclaw") ==
               :search_google

      assert Acquisition.classify_referer("https://google.co.uk/") == :search_google
    end

    test "distinguishes Google Maps / GBP from Google search" do
      assert Acquisition.classify_referer("https://maps.google.com/place/xyz") == :gbp
      assert Acquisition.classify_referer("https://business.google.com/dashboard") == :gbp
    end

    test "classifies Bing and DuckDuckGo" do
      assert Acquisition.classify_referer("https://www.bing.com/search?q=openclaw") ==
               :search_bing

      assert Acquisition.classify_referer("https://duckduckgo.com/?q=openclaw") == :search_ddg
    end

    test "classifies other search engines as :search_other" do
      assert Acquisition.classify_referer("https://search.yahoo.com/") == :search_other
      assert Acquisition.classify_referer("https://www.ecosia.org/") == :search_other
      assert Acquisition.classify_referer("https://kagi.com/search") == :search_other
    end

    test "classifies LinkedIn, Twitter/X, Facebook, Reddit, YouTube, Instagram" do
      assert Acquisition.classify_referer("https://www.linkedin.com/feed") == :social_linkedin
      assert Acquisition.classify_referer("https://twitter.com/i/status/1") == :social_x
      assert Acquisition.classify_referer("https://x.com/user/status/1") == :social_x
      assert Acquisition.classify_referer("https://t.co/abc") == :social_x

      assert Acquisition.classify_referer("https://www.facebook.com/") == :social_facebook
      assert Acquisition.classify_referer("https://l.facebook.com/l.php?u=...") ==
               :social_facebook

      assert Acquisition.classify_referer("https://www.reddit.com/r/openclaw") == :social_reddit
      assert Acquisition.classify_referer("https://www.youtube.com/watch?v=x") == :social_youtube
      assert Acquisition.classify_referer("https://youtu.be/x") == :social_youtube
      assert Acquisition.classify_referer("https://www.instagram.com/zyzyva") == :social_instagram
    end

    test "classifies mail clients as :email" do
      assert Acquisition.classify_referer("https://mail.google.com/mail/u/0") == :email
      assert Acquisition.classify_referer("https://outlook.live.com/mail") == :email
      assert Acquisition.classify_referer("https://app.fastmail.com/") == :email
    end

    test "unknown referer domains fall back to :referral_other" do
      assert Acquisition.classify_referer("https://example.com/blog") == :referral_other
      assert Acquisition.classify_referer("https://hackernews.com/") == :referral_other
    end
  end

  describe "classify/2 with UTM params" do
    test "utm_source=gbp maps to :gbp regardless of referer" do
      assert Acquisition.classify("https://example.com/", %{"utm_source" => "gbp"}) == :gbp

      assert Acquisition.classify(nil, %{"utm_source" => "google_business_profile"}) ==
               :gbp

      assert Acquisition.classify(nil, %{"utm_source" => "google-business-profile"}) == :gbp
    end

    test "utm_medium=email maps to :email regardless of utm_source" do
      assert Acquisition.classify(nil, %{"utm_medium" => "email", "utm_source" => "newsletter"}) ==
               :email

      assert Acquisition.classify("https://www.linkedin.com/", %{"utm_medium" => "email"}) ==
               :email
    end

    test "named social utm_sources map to their buckets" do
      assert Acquisition.classify(nil, %{"utm_source" => "linkedin"}) == :social_linkedin
      assert Acquisition.classify(nil, %{"utm_source" => "twitter"}) == :social_x
      assert Acquisition.classify(nil, %{"utm_source" => "x"}) == :social_x
      assert Acquisition.classify(nil, %{"utm_source" => "facebook"}) == :social_facebook
    end

    test "unknown utm_source falls back to :referral_other, NOT referer" do
      # UTM is an explicit campaign tag — the marketer wants it counted as a
      # campaign even if it's not a well-known source name.
      assert Acquisition.classify("https://www.google.com/", %{"utm_source" => "podcast"}) ==
               :referral_other
    end

    test "no UTMs falls through to referer classification" do
      assert Acquisition.classify("https://www.linkedin.com/", %{}) == :social_linkedin
      assert Acquisition.classify(nil, %{}) == :direct
    end

    test "ignores empty UTM values" do
      assert Acquisition.classify("https://www.linkedin.com/", %{"utm_source" => ""}) ==
               :social_linkedin
    end
  end

  describe "build/4" do
    test "returns full acquisition map with referer + utms + landing path" do
      now = ~U[2026-04-17 14:32:00Z]

      result =
        Acquisition.build(
          "https://www.google.com/search?q=openclaw+setup",
          %{"utm_source" => "google", "utm_medium" => "organic", "utm_campaign" => "launch"},
          "/services/openclaw-setup",
          now
        )

      assert result.source == :search_google
      assert result.referer == "https://www.google.com/search"
      assert result.landing_path == "/services/openclaw-setup"
      assert result.utm_source == "google"
      assert result.utm_medium == "organic"
      assert result.utm_campaign == "launch"
      assert result.utm_content == nil
      assert result.utm_term == nil
      assert result.first_touch_at == now
    end

    test "strips query strings from stored referer" do
      result = Acquisition.build("https://www.bing.com/search?q=secret+term", %{}, "/", DateTime.utc_now())
      assert result.referer == "https://www.bing.com/search"
    end

    test "nil referer yields nil in the map" do
      result = Acquisition.build(nil, %{}, "/", DateTime.utc_now())
      assert result.referer == nil
      assert result.source == :direct
    end
  end

  describe "process dictionary helpers" do
    setup do
      Acquisition.clear()
      :ok
    end

    test "set/get/current round-trip" do
      acquisition = Acquisition.build(nil, %{}, "/", DateTime.utc_now())
      assert Acquisition.get() == nil
      Acquisition.set(acquisition)
      assert Acquisition.get() == acquisition
      assert Acquisition.current() == acquisition
    end

    test "clear removes the stored acquisition" do
      Acquisition.set(Acquisition.build(nil, %{}, "/", DateTime.utc_now()))
      Acquisition.clear()
      assert Acquisition.get() == nil
    end

    test "propagate/1 merges :source when acquisition is set" do
      Acquisition.set(Acquisition.build("https://www.linkedin.com/", %{}, "/", DateTime.utc_now()))
      assert Acquisition.propagate(%{foo: :bar}) == %{foo: :bar, source: :social_linkedin}
    end

    test "propagate/1 is a no-op when no acquisition is set" do
      assert Acquisition.propagate(%{foo: :bar}) == %{foo: :bar}
    end

    test "propagate/1 does not overwrite an existing :source in metadata" do
      Acquisition.set(Acquisition.build("https://www.linkedin.com/", %{}, "/", DateTime.utc_now()))
      assert Acquisition.propagate(%{source: :manual_override}) == %{source: :manual_override}
    end
  end
end
