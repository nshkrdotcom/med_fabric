defmodule MedFabric.Exam.Context do
  @moduledoc "Store, capture supervision, notifications and storage for an exam workflow."

  defstruct db: MedFabric.Store.Postgres,
            captures: MedFabric.Exam.Captures,
            pubsub: MedFabric.Exam.PubSub,
            artifact_dir: nil,
            encounter_ids: []
end
