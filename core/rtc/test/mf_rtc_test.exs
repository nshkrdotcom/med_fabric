defmodule MedFabric.RtcTest do
  use ExUnit.Case, async: true

  alias MedCore.Session

  test "links encounter_ref into MedCore.Session and resolves MedRTC" do
    session = MedFabric.Rtc.new_session("enc_1", "sess_1")

    assert %Session{
             id: "sess_1",
             encounter_ref: "enc_1",
             topology: :server_terminated
           } = session

    assert MedFabric.Rtc.runtime_core_version() == MedCore.version()
  end
end
