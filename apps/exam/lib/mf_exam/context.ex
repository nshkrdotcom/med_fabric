defmodule MedFabric.Exam.Context do
  @moduledoc "Explicit host composition. Reusable Domain, Store and Interop never select a global database."
  @enforce_keys [:db,:artifact_dir,:root_owner,:registry,:writers,:pubsub]
  defstruct @enforce_keys
end
