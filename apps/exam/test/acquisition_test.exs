defmodule MedFabric.Exam.AcquisitionTest do
  use ExUnit.Case, async: true
  alias MedFabric.Exam.Acquisition

  defp snapshot,
    do: %{
      authority: "authorized",
      closed_at: nil,
      current_binding: true,
      now: ~U[2026-11-24 12:00:00Z],
      expires_at: ~U[2026-11-24 12:00:30Z],
      quiescent: true,
      state: "capturing",
      reserved: true,
      writer_open: true,
      final_covered: true
    }

  test "authority, quiescence, raw admission and terminal coverage are independent predicates" do
    assert {:ok, %{effect: :push}} = Acquisition.plan(snapshot(), :push)

    assert {:error, :authority_ended} =
             Acquisition.plan(%{snapshot() | current_binding: false}, :push)

    assert {:error, :authority_ended} =
             Acquisition.plan(%{snapshot() | now: snapshot().expires_at}, :checkpoint)

    assert {:error, :illegal_transition} =
             Acquisition.plan(%{snapshot() | quiescent: false}, :open)

    assert {:error, :illegal_transition} =
             Acquisition.plan(%{snapshot() | final_covered: false}, :finish)

    assert {:error, :illegal_transition} =
             Acquisition.plan(%{snapshot() | state: "finalizing"}, :push)

    assert {:ok, %{effect: :retire, preserve: :verified_prefix}} =
             Acquisition.plan(%{snapshot() | authority: "revoked"}, :unknown)
  end

  test "finalization requires prior effects quiescent and never creates raw admission" do
    assert {:ok, %{effect: :verify_stage_promote, admission: :closed}} =
             Acquisition.plan(
               %{snapshot() | state: "finalizing", authority: "expired"},
               :finalize
             )

    assert {:error, _} =
             Acquisition.plan(
               %{snapshot() | state: "finalizing", authority: "expired", quiescent: false},
               :finalize
             )
  end
end
