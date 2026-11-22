defmodule MedFabric.Exam.SessionBridge do
  @moduledoc """
  Product-local bridge translating Med Fabric encounter authorization and
  correlation IDs (`encounter_ref`, `acquisition_id`) onto the `:med_ex` SDK.
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

  @spec sdk_version() :: String.t()
  def sdk_version, do: MedWeb.runtime_core_version()
end
