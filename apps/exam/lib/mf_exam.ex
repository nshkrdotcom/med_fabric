defmodule MedFabric.Exam do
  @moduledoc """
  Connected remote clinical examination product within Med Fabric.

  Composes Med Fabric's pure encounter domain (`MedFabric.Domain.Encounter`)
  directly with the single Welded `:med_ex` SDK (`MedCore.Session`,
  `MedRTC.SessionServer`, `MedWeb.Signaling`) with no intermediate forwarding
  wrapper.
  """

  alias MedCore.Session
  alias MedFabric.Domain.Encounter

  @doc """
  Creates a `:med_ex` live session correlated to an encounter (`encounter_ref`).
  """
  @spec start_session(String.t(), String.t(), keyword()) :: Session.t()
  def start_session(encounter_ref, session_id, opts \\ [])
      when is_binary(encounter_ref) and is_binary(session_id) do
    Session.new(
      id: session_id,
      encounter_ref: encounter_ref,
      topology: Keyword.get(opts, :topology, :server_terminated),
      streams: Keyword.get(opts, :streams, [])
    )
  end

  @doc """
  Translates `{:emit_fact, kind, payload}` effects emitted by `:med_ex` into
  `MedFabric.Domain.Encounter` transitions.
  """
  @spec ingest_effects(Encounter.t(), [Session.effect()]) :: Encounter.t()
  def ingest_effects(%Encounter{} = encounter, effects) when is_list(effects) do
    Enum.reduce(effects, encounter, fn
      {:emit_fact, kind, payload}, acc -> Encounter.apply_fact(acc, {kind, payload})
      _other_effect, acc -> acc
    end)
  end
end
