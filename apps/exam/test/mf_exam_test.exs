defmodule MedFabric.ExamTest do
  use ExUnit.Case, async: true

  alias MedCore.Session
  alias MedFabric.Exam.SessionBridge

  test "consumes the single :med_ex SDK for session correlation and runtime wiring" do
    session = MedFabric.Exam.start_session("enc_42", "sess_9")

    assert %Session{
             id: "sess_9",
             encounter_ref: "enc_42",
             topology: :server_terminated
           } = session

    assert SessionBridge.sdk_version() == MedCore.version()
    assert MedRTC.core_version() == MedCore.version()
  end
end
