defmodule MedFabric.Exam.PersistedFrame do
  @moduledoc false
  @max 9_223_372_036_854_775_807

  # The wire remains uint64. Exam persists both the sequence and its successor,
  # together with the exclusive sample end, in PostgreSQL signed bigint fields.
  def valid?(%{sequence: sequence, first_sample: first, sample_count: count})
      when is_integer(sequence) and is_integer(first) and is_integer(count),
      do:
        sequence >= 0 and sequence < @max and first >= 0 and first <= @max and
          count > 0 and count <= @max - first

  def valid?(_), do: false
end
