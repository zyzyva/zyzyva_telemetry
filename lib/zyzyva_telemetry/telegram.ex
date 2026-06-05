defmodule ZyzyvaTelemetry.Telegram do
  @moduledoc """
  Best-effort Telegram Bot API notifier for ecosystem alerts.

  Posts plain-text messages to a Telegram chat via the Bot API `sendMessage`
  endpoint. Delivery is **fire-and-forget**: the HTTP post runs in a detached
  task and a failed post is logged (so it still lands in Loki) but never
  propagates to the caller. An alert outage can't break the product flow that
  triggered it.

  ## Configuration

      config :zyzyva_telemetry, ZyzyvaTelemetry.Telegram,
        bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
        chat_id: System.get_env("TELEGRAM_CHAT_ID")

  When `bot_token` or `chat_id` is missing, `notify/2` is a no-op that returns
  `:ok` — dev and test environments stay silent without extra guards.

  ## Routing alerts to their own room

  All ecosystem alerts share one bot + chat by default. To split a category
  (e.g. user feedback) into its own Telegram room later, set a different
  `chat_id` — globally in config, or per-call via the `:chat_id` option:

      ZyzyvaTelemetry.Telegram.notify("...", chat_id: feedback_chat_id)

  A different `bot_token` works the same way for full isolation. No code change
  is needed beyond supplying the new id/token.
  """

  require Logger

  @api_base "https://api.telegram.org"

  @doc """
  Sends `text` to the configured Telegram chat, best-effort.

  Returns `:ok` immediately; the HTTP post runs in a detached task. Failures
  are logged (and therefore visible in Loki) but never raised.

  ## Options

    * `:chat_id` — override the configured chat (route to a different room)
    * `:bot_token` — override the configured bot
    * `:parse_mode` — Telegram parse mode (`"HTML"`, `"MarkdownV2"`); omitted
      by default so `text` is treated as plain text
    * `:reply_to_message_id` — thread this message under an existing one (used
      by the feedback-triage agent to post progress under the original report)
  """
  @spec notify(String.t(), keyword()) :: :ok
  def notify(text, opts \\ []) when is_binary(text) and is_list(opts) do
    case request_spec(text, opts) do
      {:ok, url, payload} ->
        Task.start(fn -> deliver(url, payload) end)
        :ok

      :disabled ->
        log_disabled(config())
        :ok
    end
  end

  # No config block for this app/env — alerting is intentionally off (e.g. dev).
  # Stay quiet so local runs aren't spammed.
  defp log_disabled(nil),
    do: Logger.debug("[telegram] not configured; skipping notify")

  # A config block exists but bot_token/chat_id didn't resolve — alerting was
  # wired but is misconfigured (e.g. env vars unset in prod). Emit a warning so
  # it surfaces in Loki/Grafana (warnings ship under LokiLogger's default
  # min_level) instead of silently dropping the alert.
  defp log_disabled(_present),
    do:
      Logger.warning(
        "[telegram] alerting enabled but bot_token/chat_id missing — alert dropped; " <>
          "check TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID"
      )

  @doc """
  Whether a bot token and chat id are currently configured.
  """
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _url, _payload}, request_spec("", []))

  @doc false
  @spec request_spec(String.t(), keyword()) :: {:ok, String.t(), map()} | :disabled
  def request_spec(text, opts) do
    cfg = config()
    token = opts[:bot_token] || cfg[:bot_token]
    chat_id = opts[:chat_id] || cfg[:chat_id]

    build_spec(token, chat_id, text, opts)
  end

  # Pure {url, payload} builder, or :disabled when credentials are absent.
  defp build_spec(token, chat_id, _text, _opts) when token in [nil, ""] or chat_id in [nil, ""],
    do: :disabled

  defp build_spec(token, chat_id, text, opts) do
    payload =
      %{chat_id: chat_id, text: text}
      |> maybe_put(:reply_to_message_id, opts[:reply_to_message_id])
      |> maybe_put(:parse_mode, opts[:parse_mode])

    {:ok, "#{@api_base}/bot#{token}/sendMessage", payload}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp deliver(url, payload) do
    case Req.post(url, json: payload) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[telegram] sendMessage failed: HTTP #{status} #{inspect(body)}")

      {:error, reason} ->
        Logger.warning("[telegram] sendMessage error: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("[telegram] sendMessage raised: #{Exception.message(e)}")
  end

  # Returns nil when no config block exists (intentionally off), or the
  # keyword list when one is present (so missing creds can be flagged). Reading
  # keys off nil via Access is safe and yields nil.
  defp config, do: Application.get_env(:zyzyva_telemetry, __MODULE__)
end
