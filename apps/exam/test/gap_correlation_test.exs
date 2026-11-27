defmodule MedFabric.Exam.GapCorrelationTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.Control
  alias MedFabric.ExamWeb.AcquisitionSocket

  test "noncanonical and overlong gap operations are denied before reserving credit" do
    binding = %{
      "acquisition" => "a",
      "profile" => "paired_exam",
      "generation" => "1",
      "connection" => "c"
    }

    state = %{
      writer: self(),
      bind: %{},
      binding: binding,
      ledger: :untouched,
      flush: nil,
      operation_id: "initial"
    }

    for {id, operation_id} <- [{"loss", "different"}, {String.duplicate("a", 93), "gap-request"}] do
      raw =
        MedEx.CanonicalJSON.encode(%{
          "schema" => "medex.acquisition.v2",
          "type" => "gap",
          "binding" => binding,
          "operation_id" => operation_id,
          "id" => id,
          "first" => "0",
          "end" => "2",
          "first_sequence" => "0",
          "next_sequence" => "1",
          "irreversible" => true,
          "cause" => "source_gap"
        })

      assert {:stop, :normal, 1008, {:text, "acquisition_request_denied"}, returned} =
               AcquisitionSocket.handle_in({raw, [opcode: :text]}, state)

      assert returned.ledger == :untouched
    end

    assert {:error, :invalid_message} =
             Control.decode(
               MedEx.CanonicalJSON.encode(%{
                 "schema" => "medex.acquisition.v2",
                 "type" => "gap",
                 "binding" => binding,
                 "operation_id" => "gap-request",
                 "id" => String.duplicate("a", 93),
                 "first" => "0",
                 "end" => "2",
                 "first_sequence" => "0",
                 "next_sequence" => "1",
                 "irreversible" => true,
                 "cause" => "source_gap"
               }),
               ["gap"]
             )
  end
end
