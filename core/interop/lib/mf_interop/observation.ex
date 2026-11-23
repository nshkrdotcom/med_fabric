defmodule MedFabric.Interop.Observation do
  @moduledoc "Compares the clinical content returned by FHIR with the accepted observation."

  # Identifier membership is confirmed separately, together with the remote resource ID.
  @server_fields ~w(id meta text identifier)

  def matches?(%{"valueQuantity" => quantity} = expected, %{"valueQuantity" => actual} = remote),
    do: quantity == actual and common_match?(expected, remote, "valueQuantity")

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

      Map.drop(expected, fields) == Map.drop(normalized, fields)
    else
      _ -> false
    end
  end

  defp strip_reference_display(remote, field, expected) do
    case {expected[field], remote[field]} do
      {%{"reference" => _} = ref, %{} = actual} when not is_map_key(ref, "display") ->
        Map.put(remote, field, Map.delete(actual, "display"))

      _ ->
        remote
    end
  end
end
