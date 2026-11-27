defmodule MedFabric.Exam.PersistedFrameTest do
  use ExUnit.Case, async: true
  alias MedEx.Wire.FrameV1
  alias MedFabric.Exam.PersistedFrame
  alias MedFabric.ExamWeb.AcquisitionSocket
  @max 9_223_372_036_854_775_807

  test "the persisted next sequence and exclusive sample end fit signed bigint" do
    for {sequence, first, count, accepted} <- [
          {0, 0, 1, true},
          {@max - 1, @max - 1, 1, true},
          {@max, 0, 1, false},
          {@max + 1, 0, 1, false},
          {0xFFFFFFFFFFFFFFFF, 0, 1, false},
          {0, @max - 2, 2, true},
          {0, @max - 1, 2, false},
          {0, @max, 1, false},
          {0, 0xFFFFFFFFFFFFFFFF, 1, false},
          {-1, 0, 1, false},
          {0, -1, 1, false},
          {0, 0, 0, false},
          {0, 0, -1, false},
          {0, 0, 1.0, false},
          {9_007_199_254_740_993, 9_007_199_254_740_993, 2, true}
        ] do
      assert PersistedFrame.valid?(%{
               sequence: sequence,
               first_sample: first,
               sample_count: count
             }) ==
               accepted
    end

    refute PersistedFrame.valid?(nil)
    refute PersistedFrame.valid?(%{})
  end

  test "socket denies SQL-overflow wire values before credit or any dependency call" do
    for {sequence, first} <- [{@max, 0}, {@max + 1, 0}, {0, @max}, {0, @max - 1}] do
      frame = %FrameV1{
        stream_number: 1,
        source_epoch: 0,
        config_epoch: :unknown,
        sequence: sequence,
        first_sample: first,
        sample_count: 2,
        payload: <<0, 0, 0, 0>>
      }

      assert {:ok, raw} = FrameV1.encode(frame)
      assert {:ok, ^frame} = FrameV1.decode(raw)
      # No database/root owner or credit state: any effect would fail this test.
      state = %{writer: self(), flush: nil, ledger: :untouched}

      assert {:stop, :normal, 1008, {:text, "acquisition_request_denied"}, ^state} =
               AcquisitionSocket.handle_in({raw, [opcode: :binary]}, state)
    end
  end
end
