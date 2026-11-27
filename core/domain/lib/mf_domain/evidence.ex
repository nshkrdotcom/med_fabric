defmodule MedFabric.Domain.Evidence do
  @moduledoc "Immutable native manual evidence. Entry and clinician acceptance are separate actions."

  def pulse_rate(value, %DateTime{} = at, actor)
      when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807 and
             is_binary(actor) and byte_size(actor) in 1..256 do
    {:ok, %{"kind" => "pulse_rate", "value" => %{"mantissa" => to_string(value), "exponent" => "0"},
      "unit" => "/min", "effective_at" => DateTime.to_iso8601(at),
      "provenance" => %{"kind" => "manual", "actor" => actor,
        "recorded_at" => DateTime.to_iso8601(at)}}}
  end

  def pulse_rate(_, _, _), do: {:error, :invalid_pulse_rate}

  def validate(%{"kind" => "pulse_rate", "value" => value, "unit" => "/min",
      "effective_at" => effective, "provenance" => %{"kind" => "manual", "actor" => actor,
      "recorded_at" => recorded} = provenance} = evidence) do
    with true <- Enum.sort(Map.keys(evidence)) == ~w(effective_at kind provenance unit value),
         true <- Enum.sort(Map.keys(provenance)) == ~w(actor kind recorded_at),
         true <- is_binary(actor) and String.valid?(actor) and byte_size(actor) in 1..256,
         true <- MedFabric.Domain.NativeValue.eligible?("pulse_rate",value),
         {:ok, at, 0} <- parse_time(effective), {:ok, entered, 0} <- parse_time(recorded),
         true <- DateTime.compare(at,entered) != :gt do
      :ok
    else _ -> {:error,:invalid_manual_evidence} end
  end
  def validate(_),do: {:error,:invalid_manual_evidence}
  defp parse_time(value) when is_binary(value) and byte_size(value) <= 32,do: DateTime.from_iso8601(value)
  defp parse_time(_),do: {:error,:invalid_time}

end
