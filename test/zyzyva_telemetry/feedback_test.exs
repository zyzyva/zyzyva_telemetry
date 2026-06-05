defmodule ZyzyvaTelemetry.FeedbackTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ZyzyvaTelemetry.{Feedback, Telegram}

  setup do
    prev_tg = Application.get_env(:zyzyva_telemetry, Telegram)
    prev_svc = Application.get_env(:zyzyva_telemetry, :service_name)

    # Keep Telegram unconfigured so report/1 never hits the network.
    Application.delete_env(:zyzyva_telemetry, Telegram)
    Application.put_env(:zyzyva_telemetry, :service_name, "contacts4us")

    on_exit(fn ->
      restore(:service_name, prev_svc)
      restore(Telegram, prev_tg)
    end)

    :ok
  end

  describe "format_message/2" do
    test "includes type emoji, service, subject, message, and ref" do
      msg =
        Feedback.format_message("bug_report", %{
          service: "contacts4us",
          subject: "vCard import fails",
          message: "It crashes on iOS 17",
          feedback_id: 123,
          user_id: 45
        })

      assert msg =~ "🐛"
      assert msg =~ "Bug report · contacts4us"
      assert msg =~ "Subject: vCard import fails"
      assert msg =~ "It crashes on iOS 17"
      assert msg =~ "#123"
      assert msg =~ "user 45"
    end

    test "truncates long messages" do
      long = String.duplicate("a", 1000)
      msg = Feedback.format_message("general", %{message: long})

      assert String.length(msg) < 1000
      assert msg =~ "…"
    end

    test "omits missing optional lines" do
      msg = Feedback.format_message("suggestion", %{})

      assert msg =~ "Suggestion"
      refute msg =~ "Subject:"
      refute msg =~ "ref:"
    end

    test "falls back to configured service_name when not in metadata" do
      msg = Feedback.format_message("general", %{message: "hi"})
      assert msg =~ "· contacts4us"
    end
  end

  describe "report/1" do
    test "records a feedback telemetry event and returns :ok" do
      id = attach([:zyzyva_telemetry, :feedback, :received])

      capture_log(fn ->
        assert Feedback.report(%{
                 type: "bug_report",
                 subject: "x",
                 message: "y",
                 id: 7,
                 user_id: 9
               }) == :ok
      end)

      assert_receive {[:zyzyva_telemetry, :feedback, :received], %{count: 1}, md}
      assert md.feedback_type == "bug_report"
      assert md.service == "contacts4us"

      :telemetry.detach(id)
    end

    test "still returns :ok when Telegram is unconfigured" do
      capture_log(fn ->
        assert Feedback.report(%{type: "general", message: "hi"}) == :ok
      end)
    end

    test "defaults missing type to general" do
      log = capture_log(fn -> assert Feedback.report(%{message: "hi"}) == :ok end)
      assert log =~ "feedback: general"
    end
  end

  defp attach(event) do
    id = {:fb_capture, :erlang.unique_integer()}
    test_pid = self()

    :telemetry.attach(id, event, fn e, m, md, _ -> send(test_pid, {e, m, md}) end, nil)

    id
  end

  defp restore(key, nil), do: Application.delete_env(:zyzyva_telemetry, key)
  defp restore(key, value), do: Application.put_env(:zyzyva_telemetry, key, value)
end
