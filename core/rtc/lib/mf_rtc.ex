defmodule MedFabric.Rtc do
  @moduledoc """
  Encounter-to-MedEx live session bridge within Med Fabric.

  Translates encounter correlation IDs and permissions into `MedCore.Session`
  and `MedRTC` transport calls without duplicating WebRTC or Membrane state.
  """

  alias MedCore.Session

  @spec new_session(String.t(), String.t(), MedCore.Profile.topology()) :: Session.t()
  def new_session(encounter_ref, session_id, topology \\ :server_terminated)
      when is_binary(encounter_ref) and is_binary(session_id) do
    %Session{
      id: session_id,
      encounter_ref: encounter_ref,
      topology: topology,
      streams: %{}
    }
  end

  @spec runtime_core_version() :: String.t()
  def runtime_core_version, do: MedRTC.core_version()
end
