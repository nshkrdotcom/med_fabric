defmodule MedFabric.Exam.LogPrivacyTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  require Logger
  alias MedFabric.Exam.LogPrivacy

  defmodule Fault do
    use GenServer
    def init(secret), do: {:ok, secret}
    def handle_cast(:fail, state), do: {:stop, {:synthetic_failure, state}, state}
  end

  test "host filter is idempotent and keeps safe warnings while redacting dependency metadata" do
    assert :ok = LogPrivacy.install()
    assert :ok = LogPrivacy.install()
    assert Enum.count(:logger.get_primary_config().filters, &(elem(&1, 0) == :mf_exam_privacy)) == 1
    secret = "synthetic-clinical-token-2a398fa1"

    log = capture_log(fn ->
      :logger.warning(secret, %{mfa: {Postgrex.Protocol, :query, 3}, clinical_body: secret})
      Logger.warning("safe_exam_diagnostic")
    end)

    assert log =~ "mf_exam_dependency_event"
    assert log =~ "safe_exam_diagnostic"
    refute log =~ secret
  end

  test "real OTP crash reports cannot dump host state or mailbox contents" do
    secret = "synthetic-mailbox-secret-f0d5974c"

    log = capture_log(fn ->
      {:ok, pid} = GenServer.start(Fault, secret)
      ref = Process.monitor(pid)
      GenServer.cast(pid, :fail)
      send(pid, {:clinical, secret})
      assert_receive {:DOWN, ^ref, :process, ^pid, {:synthetic_failure, ^secret}}
      Logger.flush()
    end)

    assert log =~ "mf_exam_otp_report"
    refute log =~ secret
  end

  test "unrelated OTP reports are left intact and sanitized severity is unchanged" do
    unrelated = %{level: :warning, msg: {:report, %{label: {:unrelated, :event}, value: :safe}}, meta: %{domain: [:otp]}}
    assert :ignore = LogPrivacy.filter(unrelated, [])
    sensitive = %{unrelated | msg: {:string, "secret"}, meta: %{mfa: {Postgrex.Protocol, :query, 3}, token: "secret"}}
    assert %{level: :warning, msg: {:string, "mf_exam_dependency_event"}, meta: %{mfa: {Postgrex.Protocol, :query, 3}}} =
             LogPrivacy.filter(sensitive, [])
  end

  test "delayed proc_lib reports retain ownership after the originating process has exited" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    secret = "synthetic-delayed-crash-secret-19d2e5a0"
    owned = [initial_call: {MedFabric.Exam.LogPrivacyTest.Fault, :init, 1}, messages: [secret]]
    unrelated = [initial_call: {:unrelated_worker, :init, 1}]

    for reports <- [[owned, []], [unrelated, [{:neighbour, owned}]]] do
      report = %{label: {:proc_lib, :crash}, report: reports}
      meta = %{domain: [:otp, :sasl], pid: pid}
      event = %{level: :error, msg: {:report, report}, meta: meta}
      assert %{level: :error, msg: {:string, "mf_exam_otp_report"}} =
               LogPrivacy.filter(event, [])

      log = capture_log(fn -> :logger.error(report, meta) end)
      assert log =~ "mf_exam_otp_report"
      refute log =~ secret
    end
  end

  test "application exit reports redact only this system's executable hosts" do
    for app <- [:mf_exam, :mf_preview, :mf_handheld] do
      report = %{label: {:application_controller, :exit}, application: app, exited: "secret"}
      event = %{level: :notice, msg: {:report, report}, meta: %{domain: [:otp]}}
      assert %{level: :notice, msg: {:string, "mf_exam_otp_report"}} =
               LogPrivacy.filter(event, [])
      assert :ignore = LogPrivacy.filter(%{event | msg: {:report, %{report | application: :other}}}, [])
    end
  end
end
