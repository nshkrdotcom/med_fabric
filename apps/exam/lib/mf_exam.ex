defmodule MedFabric.Exam do
  @moduledoc """
  Connected remote clinical examination product within Med Fabric.

  Composes Med Fabric's durable encounter workflow (`mf_domain`, `mf_runtime`,
  `mf_store`, `mf_interop`) with the single Welded `:med_ex` SDK (`MedCore`,
  `MedRTC`, `MedWeb`).
  """

  alias MedFabric.Exam.SessionBridge

  @spec start_session(String.t(), String.t(), keyword()) :: MedCore.Session.t()
  def start_session(encounter_ref, session_id, opts \\ []) do
    SessionBridge.new_session(encounter_ref, session_id, opts)
  end
end
