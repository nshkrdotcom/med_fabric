defmodule MedFabric.Handheld.SourceTest do
  use ExUnit.Case, async: true

  alias MedFabric.Handheld.{PLXPeripheral, RDP1, ReferencePeripheral}

  test "RDP1 independent CRC vector survives every split and coalesced reads" do
    bytes = File.read!(Path.join(__DIR__, "fixtures/rdp1_waveform.bin"))
    {:ok, "", [event]} = RDP1.decode("", bytes)
    assert event.sample_count > 0

    for split <- 0..byte_size(bytes) do
      <<left::binary-size(^split), right::binary>> = bytes
      {:ok, buf, events} = RDP1.decode("", left)
      {:ok, "", rest} = RDP1.decode(buf, right <> bytes)
      assert events ++ rest == [event, event]
    end

    <<a::binary-size(35), n, rest::binary>> = bytes
    assert {:error, :bad_crc, _} = RDP1.decode("", a <> <<Bitwise.bxor(n, 1)>> <> rest)
    assert {:error, :framing_limit, _} = RDP1.decode("", :binary.copy(<<0>>, 4200))
  end

  test "raw control request replay cannot restart sampling and changed request conflicts" do
    p = ReferencePeripheral.new(1, 71)

    body = %{
      "schema" => "rdp1.control.v1",
      "request_id" => "start-1",
      "op" => "start",
      "args" => %{"acquisition" => "test", "profile" => "reference"}
    }

    packet = fn m -> RDP1.packet(16, 1, 71, 0, 0, 0, 0, JSON.encode!(m)) end
    {p, reply} = ReferencePeripheral.request(p, packet.(body))
    {p, raw} = ReferencePeripheral.emit(p, 32, 80, 1)
    assert {^p, ^reply} = ReferencePeripheral.request(p, packet.(body))
    {_, [conflict]} = ReferencePeripheral.request(p, packet.(%{body | "op" => "stop"}))
    assert ReferencePeripheral.fragmented(conflict).body["error"] == "request_conflict"
    {_, _, [replayed]} = ReferencePeripheral.transact(p, "replay", %{"first" => 0, "next" => 1})
    assert replayed == raw
  end

  test "RACP count/report/abort/timeout retain device records" do
    p = PLXPeripheral.new()
    assert {^p, {:error, :cccd_improperly_configured}} = PLXPeripheral.racp(p, <<4, 1>>)
    p = PLXPeripheral.subscribe(p)
    {^p, <<5, 0, 2::little-16>>} = PLXPeripheral.racp(p, <<4, 1>>)
    {busy, {:indications, rows}} = PLXPeripheral.racp(p, <<1, 1>>)
    assert {^busy, {:error, :procedure_in_progress}} = PLXPeripheral.racp(busy, <<1, 1>>)
    assert {^p, <<6, 0, 3, 1>>} = PLXPeripheral.racp(busy, <<3, 0>>)
    assert {^p, :outcome_unknown} = PLXPeripheral.timeout(busy)
    assert rows == p.records
  end
end
