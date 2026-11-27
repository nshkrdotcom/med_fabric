defmodule MedFabric.Domain.NativeValue do
  @moduledoc "Exact native decimal validation; no floating point or external representation rules."

  def parse(%{"mantissa" => m, "exponent" => e} = value) when map_size(value) == 2 do
    with {:ok, mantissa} <- signed(m, 21), {:ok, exponent} <- signed(e, 3),
         true <- abs(mantissa) <= 18_446_744_073_709_551_615 and exponent in -18..18 do
      {:ok, {mantissa, exponent}}
    else
      _ -> {:error, :invalid_native_decimal}
    end
  end

  def parse(_), do: {:error, :invalid_native_decimal}

  def eligible?(code, value) do
    case parse(value) do
      {:ok, {m, e}} when m >= 0 -> code != "spo2" or at_most?(m, e, 100)
      _ -> false
    end
  end

  defp at_most?(m, e, limit) when e >= 0, do: m * Integer.pow(10, e) <= limit
  defp at_most?(m, e, limit), do: m <= limit * Integer.pow(10, -e)

  defp signed(s, max) when is_binary(s) and byte_size(s) in 1..max do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*|-[1-9][0-9]*)\z/, s),
      do: {:ok, String.to_integer(s)}, else: {:error, :noncanonical_decimal}
  end
  defp signed(_, _), do: {:error, :noncanonical_decimal}
end
