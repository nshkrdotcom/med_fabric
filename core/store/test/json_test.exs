defmodule MedFabric.Store.JSONTest do
  use ExUnit.Case, async: true
  alias MedFabric.Store.JSON, as: StoreJSON

  test "JSONB codec preserves the exact outbox number without a float or string conversion" do
    value = Decimal.new("97.2000000000000001")

    bytes =
      StoreJSON.encode_to_iodata!(%{"valueQuantity" => %{"value" => value}})
      |> IO.iodata_to_binary()

    assert bytes == "{\"valueQuantity\":{\"value\":97.2000000000000001}}"
    decoded = StoreJSON.decode!(bytes)
    assert Decimal.equal?(decoded["valueQuantity"]["value"], value)
    assert StoreJSON.decode!("{\"integer\":72}") == %{"integer" => 72}
  end
end
