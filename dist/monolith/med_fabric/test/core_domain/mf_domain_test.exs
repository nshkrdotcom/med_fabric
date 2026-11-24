defmodule MedFabric.Domain.EncounterTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.Encounter

  test "review binds the complete file and blocks conflicting evidence" do
    m = %{"file_sha256" => "first"}
    assert :ok = Encounter.review(m, "first", false)
    assert {:error, :recording_changed} = Encounter.review(m, "different", false)
    assert {:error, :conflicting_recording} = Encounter.review(m, "first", true)
  end
end
