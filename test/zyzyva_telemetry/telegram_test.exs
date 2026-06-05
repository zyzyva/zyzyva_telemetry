defmodule ZyzyvaTelemetry.TelegramTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.Telegram

  setup do
    prev = Application.get_env(:zyzyva_telemetry, Telegram)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:zyzyva_telemetry, Telegram)
        cfg -> Application.put_env(:zyzyva_telemetry, Telegram, cfg)
      end
    end)

    :ok
  end

  describe "request_spec/2" do
    test "returns :disabled when no token/chat configured" do
      Application.delete_env(:zyzyva_telemetry, Telegram)
      assert Telegram.request_spec("hi", []) == :disabled
    end

    test "returns :disabled when only one of token/chat is set" do
      Application.put_env(:zyzyva_telemetry, Telegram, bot_token: "123:abc")
      assert Telegram.request_spec("hi", []) == :disabled
    end

    test "builds sendMessage url + payload when configured" do
      Application.put_env(:zyzyva_telemetry, Telegram, bot_token: "123:abc", chat_id: "-100999")

      assert {:ok, url, payload} = Telegram.request_spec("hello", [])
      assert url == "https://api.telegram.org/bot123:abc/sendMessage"
      assert payload == %{chat_id: "-100999", text: "hello"}
    end

    test "per-call chat_id overrides config (route to its own room)" do
      Application.put_env(:zyzyva_telemetry, Telegram, bot_token: "123:abc", chat_id: "-100999")

      assert {:ok, _url, payload} = Telegram.request_spec("hi", chat_id: "-100555")
      assert payload.chat_id == "-100555"
    end

    test "includes reply_to_message_id and parse_mode when given" do
      Application.put_env(:zyzyva_telemetry, Telegram, bot_token: "t", chat_id: "c")

      assert {:ok, _url, payload} =
               Telegram.request_spec("hi", reply_to_message_id: 42, parse_mode: "HTML")

      assert payload.reply_to_message_id == 42
      assert payload.parse_mode == "HTML"
    end
  end

  describe "notify/2 and configured?/0" do
    test "notify/2 no-ops and returns :ok when unconfigured" do
      Application.delete_env(:zyzyva_telemetry, Telegram)
      capture_log(fn -> assert Telegram.notify("hi") == :ok end)
    end

    test "configured?/0 reflects config presence" do
      Application.delete_env(:zyzyva_telemetry, Telegram)
      refute Telegram.configured?()

      Application.put_env(:zyzyva_telemetry, Telegram, bot_token: "t", chat_id: "c")
      assert Telegram.configured?()
    end
  end
end
