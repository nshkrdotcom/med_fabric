defmodule MedFabric.Store.JSON do
  @moduledoc "Postgrex JSONB codec preserving fractional quantities as exact Decimal values."
  def encode!(value), do: Elixir.JSON.encode!(value, &encode_value/2)
  def encode_to_iodata!(value), do: Elixir.JSON.encode_to_iodata!(value, &encode_value/2)

  def decode!(bytes) do
    case Elixir.JSON.decode(IO.iodata_to_binary(bytes), nil, float: &Decimal.new/1) do
      {value, nil, rest} ->
        if String.trim(rest) == "", do: value, else: raise(ArgumentError, "trailing JSONB content")
      {:error, reason} -> raise ArgumentError, "invalid JSONB: #{inspect(reason)}"
    end
  end

  defp encode_value(%Decimal{} = value, _encoder) do
    if Decimal.nan?(value) or Decimal.inf?(value), do: raise(ArgumentError, "nonfinite JSONB decimal")
    Decimal.to_string(value, :normal)
  end
  defp encode_value(value, encoder), do: Elixir.JSON.protocol_encode(value, encoder)
end
