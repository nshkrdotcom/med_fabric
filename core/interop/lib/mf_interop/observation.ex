defmodule MedFabric.Interop.Observation do
  @moduledoc "Compares the clinical content returned by FHIR with the accepted observation."

  # Identifier membership is confirmed separately, together with the remote resource ID.
  @server_fields ~w(id meta text identifier)

  def matches?(%{"valueQuantity" => quantity} = expected, %{"valueQuantity" => actual} = remote),
    do: quantity_match?(quantity, actual) and common_match?(expected, remote, "valueQuantity")

  def matches?(%{"valueString" => digest} = expected, %{"valueString" => digest} = remote),
    do: common_match?(expected, remote, "valueString")

  def matches?(_, _), do: false

  defp common_match?(expected, remote, value_field) do
    fields = [value_field | @server_fields]

    with %{"code" => %{"coding" => [coding]}} <- expected,
         %{"code" => %{"coding" => [actual]}} when is_map(actual) <- remote do
      normalized =
        remote
        |> update_in(["code", "coding"], fn _ ->
          [if(Map.has_key?(coding, "display"), do: actual, else: Map.delete(actual, "display"))]
        end)
        |> strip_reference_display("subject", expected)
        |> strip_reference_display("encounter", expected)
        |> strip_reference_display("device", expected)

      required_metadata?(expected["meta"], remote["meta"]) and
        normalize_instants(Map.drop(expected, fields)) ==
          normalize_instants(Map.drop(normalized, fields))
    else
      _ -> false
    end
  end

  # FHIR servers may render the same fully qualified instant using +00:00 or
  # additional fractional zeroes. Only formatting is normalized; an actual
  # instant change, partial date, missing timezone or non-string stays different.
  defp normalize_instants(resource) do
    Enum.reduce(["effectiveDateTime", "issued"], resource, fn key, acc ->
      case acc[key] do
        value when is_binary(value) ->
          if Regex.match?(~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z/, value) do
            case DateTime.from_iso8601(value) do
              {:ok, instant, _offset} -> Map.put(acc, key, {:instant_us, DateTime.to_unix(instant, :microsecond)})
              _ -> acc
            end
          else
            acc
          end
        _ -> acc
      end
    end)
  end

  defp strip_reference_display(remote, field, expected) do
    case {expected[field], remote[field]} do
      {%{"reference" => _} = ref, %{} = actual} when not is_map_key(ref, "display") ->
        Map.put(remote, field, Map.delete(actual, "display"))

      _ ->
        remote
    end
  end

  defp quantity_match?(%{"value" => left} = expected, %{"value" => right} = actual) do
    Map.drop(expected, ["value"]) == Map.drop(actual, ["value"]) and decimal_equal?(left, right)
  end
  defp quantity_match?(_, _), do: false

  defp decimal_equal?(left, right) when is_integer(left) and is_integer(right), do: left == right
  defp decimal_equal?(%Decimal{} = left, right) when is_integer(right),
    do: finite?(left) and Decimal.equal?(left, Decimal.new(right))
  defp decimal_equal?(left, %Decimal{} = right) when is_integer(left),
    do: finite?(right) and Decimal.equal?(Decimal.new(left), right)
  defp decimal_equal?(%Decimal{} = left, %Decimal{} = right),
    do: finite?(left) and finite?(right) and Decimal.equal?(left, right)
  defp decimal_equal?(_, _), do: false
  defp finite?(value), do: not Decimal.nan?(value) and not Decimal.inf?(value)

  defp required_metadata?(nil, _), do: true
  defp required_metadata?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn
      {key, values} when key in ["profile", "tag", "security"] and is_list(values) ->
        is_list(actual[key]) and Enum.all?(values, &(&1 in actual[key]))
      {key, value} -> actual[key] == value
    end)
  end
  defp required_metadata?(_, _), do: false
end
