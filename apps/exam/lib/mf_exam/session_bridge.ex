defmodule MedFabric.Exam.SessionBridge do
  @moduledoc """
  Product-local bridge translating Med Fabric encounter authorization and
  correlation IDs (`encounter_ref`, `acquisition_id`) onto the `:med_ex` SDK
  and feeding SDK producer facts into `MedFabric.Domain.Encounter`.
  """

  alias MedCore.Session
  alias MedFabric.Domain.Encounter

  @spec new_session(String.t(), String.t(), keyword()) :: Session.t()
  def new_session(encounter_ref, session_id, opts \\ [])
      when is_binary(encounter_ref) and is_binary(session_id) do
    Session.new(
      id: session_id,
      encounter_ref: encounter_ref,
      topology: Keyword.get(opts, :topology, :server_terminated),
      streams: Keyword.get(opts, :streams, [])
    )
  end

  @doc """
  Applies emitted `:med_ex` session effects (only `{:emit_fact, kind, payload}`
  tuples matching the encounter) to a pure `MedFabric.Domain.Encounter`.
  """
  @spec ingest_effects(Encounter.t(), [Session.effect()]) :: Encounter.t()
  def ingest_effects(%Encounter{} = encounter, effects) when is_list(effects) do
    Enum.reduce(effects, encounter, fn
      {:emit_fact, kind, payload}, acc ->
        Encounter.apply_fact(acc, {kind, payload})

      _other_effect, acc ->
        acc
    end)
  end
end
