defmodule MedFabric.Exam.Acquisition do
  @moduledoc "Pure acquisition authority/evidence decisions; technical cursor and receipts remain in MedEx."
  def plan(s, op) when is_map(s) do
    cond do
      op in [:transport_loss, :unknown] ->
        {:ok, %{effect: :retire, preserve: :verified_prefix, admission: :closed}}

      op in [:expire, :revoke, :rotate] ->
        {:ok, %{effect: :quiesce, admission: :closed, preserve: :verified_prefix}}

      op == :finalize and s.quiescent and s.state in ["finalizing", "staged", "promoted"] ->
        {:ok, %{effect: :verify_stage_promote, admission: :closed}}

      not authorized?(s) ->
        {:error, :authority_ended}

      true ->
        active_plan(s, op)
    end
  end

  def plan(_, _), do: {:error, :invalid_snapshot}

  defp active_plan(s, :reserve) do
    if s.quiescent and s.state in ["capturing", "finalizing"],
      do: {:ok, %{effect: :reserve_fence, commit_before_open: true}},
      else: {:error, :illegal_transition}
  end

  defp active_plan(s, :open) do
    if s.quiescent and s.reserved,
      do: {:ok, %{effect: :open, observe_before_ack: true}},
      else: {:error, :illegal_transition}
  end

  defp active_plan(s, op) when op in [:push, :gap, :checkpoint, :replay] do
    if s.writer_open and s.state == "capturing",
      do: {:ok, %{effect: op, scope_required: true, observe_before_ack: true}},
      else: {:error, :illegal_transition}
  end

  defp active_plan(s, :finish) do
    if s.writer_open and s.final_covered and s.state in ["capturing", "finalizing"],
      do: {:ok, %{effect: :seal, scope_required: true, verify_terminal: true}},
      else: {:error, :illegal_transition}
  end

  defp active_plan(s, :abort) do
    if s.quiescent,
      do: {:ok, %{effect: :settle_interrupted, source_append: false}},
      else: {:error, :illegal_transition}
  end

  defp active_plan(_, _), do: {:error, :illegal_transition}

  defp authorized?(s),
    do:
      s.authority == "authorized" and s.closed_at == nil and s.current_binding and
        DateTime.compare(s.now, s.expires_at) == :lt
end
