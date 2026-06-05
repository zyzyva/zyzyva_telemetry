defmodule ZyzyvaTelemetry.Feedback do
  @moduledoc """
  Ecosystem entry point for inbound user feedback / bug reports.

  `report/1` does two things from a single call site in your app's feedback
  context:

    1. Records a structured `event_type="feedback"` line to Loki (plus a
       Prometheus counter) via `ZyzyvaTelemetry.Events.track_feedback/2`. This
       is the durable queue a feedback-triage agent can read back with LogQL:

           {service="contacts4us"} | json | event_type="feedback"

    2. Posts a best-effort Telegram alert via `ZyzyvaTelemetry.Telegram` so a
       human sees the report arrive in real time.

  Telegram delivery is fire-and-forget: if it is unconfigured or the post
  fails, the feedback is still recorded to Loki and `report/1` still returns
  `:ok`. Submitting feedback in the product can never be blocked by an alert
  outage.

  ## Usage

      ZyzyvaTelemetry.Feedback.report(%{
        type: "bug_report",
        subject: "vCard import fails on iOS",
        message: "It crashes when importing a multi-contact vCard.",
        id: feedback.id,
        user_id: user.id
      })

  `:type` should match your feedback schema's low-cardinality type field
  (`"bug_report"`, `"feature_request"`, `"suggestion"`, `"general"`,
  `"review"`). Everything else rides to Loki as high-cardinality context.
  """

  alias ZyzyvaTelemetry.{Events, Telegram}

  @type_emoji %{
    "bug_report" => "🐛",
    "feature_request" => "✨",
    "suggestion" => "💡",
    "general" => "💬",
    "review" => "⭐"
  }

  @message_preview_limit 600

  @doc """
  Records feedback to telemetry and fires a best-effort Telegram alert.

  Always returns `:ok`.
  """
  @spec report(map()) :: :ok
  def report(attrs) when is_map(attrs) do
    type = to_string(Map.get(attrs, :type, "general"))

    metadata =
      attrs
      |> Map.delete(:type)
      |> rename_key(:id, :feedback_id)

    Events.track_feedback(type, metadata)
    Telegram.notify(format_message(type, metadata))
    :ok
  end

  @doc """
  Builds the plain-text Telegram alert for a feedback item. Pure — no I/O.
  """
  @spec format_message(String.t(), map()) :: String.t()
  def format_message(type, metadata) when is_binary(type) and is_map(metadata) do
    emoji = Map.get(@type_emoji, type, "📝")
    header = "#{emoji} #{humanize(type)} · #{service_name(metadata)}"

    [
      header,
      subject_line(metadata[:subject]),
      preview(metadata[:message]),
      ref_line(metadata)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # --------------------------------------------------------------------------
  # Internal
  # --------------------------------------------------------------------------

  defp service_name(metadata) do
    metadata[:service] || metadata[:app] ||
      Application.get_env(:zyzyva_telemetry, :service_name) || "app"
  end

  defp subject_line(nil), do: nil
  defp subject_line(""), do: nil
  defp subject_line(subject), do: "Subject: #{subject}"

  defp preview(nil), do: nil
  defp preview(""), do: nil

  defp preview(message) when is_binary(message) and byte_size(message) <= @message_preview_limit,
    do: message

  defp preview(message) when is_binary(message),
    do: String.slice(message, 0, @message_preview_limit) <> "…"

  defp ref_line(metadata) do
    parts =
      [ref_part("#", metadata[:feedback_id]), ref_part("user ", metadata[:user_id])]
      |> Enum.reject(&is_nil/1)

    join_ref(parts)
  end

  defp join_ref([]), do: nil
  defp join_ref(parts), do: "ref: " <> Enum.join(parts, " · ")

  defp ref_part(_prefix, nil), do: nil
  defp ref_part(prefix, value), do: "#{prefix}#{value}"

  defp rename_key(map, from, to) do
    case Map.pop(map, from) do
      {nil, rest} -> rest
      {value, rest} -> Map.put(rest, to, value)
    end
  end

  defp humanize(type) do
    type
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
