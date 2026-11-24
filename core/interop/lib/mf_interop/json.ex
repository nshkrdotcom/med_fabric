defmodule MedFabric.Interop.JSON do
  @moduledoc "FHIR JSON with exact finite numeric decimals, string keys and duplicate-key rejection."
  @max_bytes 4_194_304

  def encode!(value), do: Elixir.JSON.encode!(value, &encode_value/2)
  def encode_to_iodata!(value), do: Elixir.JSON.encode_to_iodata!(value, &encode_value/2)

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    callbacks = [
      float: &Decimal.new/1,
      object_start: fn _ -> %{} end,
      object_push: fn key, value, acc ->
        if Map.has_key?(acc, key), do: raise(ArgumentError, "duplicate JSON key")
        Map.put(acc, key, value)
      end,
      object_finish: fn acc, parent -> {acc, parent} end
    ]

    case Elixir.JSON.decode(bytes, nil, callbacks) do
      {value, nil, rest} ->
        if String.trim(rest) == "",
          do: {:ok, value},
          else: {:error, ArgumentError.exception("trailing JSON content")}

      {:error, reason} ->
        {:error, ArgumentError.exception("invalid JSON: #{inspect(reason)}")}
    end
  rescue
    error in [ArgumentError, Decimal.Error] -> {:error, error}
  end

  def decode(_),
    do: {:error, ArgumentError.exception("FHIR JSON body is absent or exceeds limit")}

  def decode!(bytes) do
    case decode(bytes) do
      {:ok, value} -> value
      {:error, error} -> raise error
    end
  end

  defp encode_value(%Decimal{} = value, _encoder) do
    if Decimal.nan?(value) or Decimal.inf?(value),
      do: raise(ArgumentError, "nonfinite FHIR decimal")

    Decimal.to_string(value, :normal)
  end

  defp encode_value(value, encoder), do: Elixir.JSON.protocol_encode(value, encoder)
end
