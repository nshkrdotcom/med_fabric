defmodule MedFabric.Domain.Review do
  @moduledoc "Pure native decision plan from verified immutable evidence and an explicit actor/time."
  alias MedFabric.Domain.{DeviceMeasurement, Evidence}

  def plan(
        %{
          kind: kind,
          id: id,
          encounter: encounter,
          digest: source_digest,
          verified: true,
          body: body
        } = source,
        actor,
        request_id,
        choice,
        %DateTime{} = at
      )
      when kind in [:manual, :acquisition] and is_map(body) and is_map(choice) do
    with true <- identifier?(request_id) and text?(actor, 256),
         true <- identifier?(id) and text?(encounter, 256) and digest?(source_digest),
         :ok <- validate_choice(source, choice),
         {:ok, observations} <- observations(source, choice, actor, at) do
      content = %{
        "source_kind" => to_string(source.kind),
        "source_id" => source.id,
        "source_digest" => source.digest,
        "encounter" => source.encounter,
        "actor" => actor,
        "choice" => choice
      }

      canonical = MedEx.CanonicalJSON.encode(content)
      decision_id = digest(["medfabric.review.v2", source.encounter, actor, request_id])

      native =
        Enum.map(observations, fn observation ->
          id = digest(["medfabric.observation.v2", decision_id, observation["selection"]])

          native =
            Map.merge(observation, %{
              "id" => id,
              "decision_id" => decision_id,
              "actor" => actor,
              "source_digest" => source.digest
            })

          Map.put(native, "digest", digest(native))
        end)

      {:ok,
       %{
         source: source,
         actor: actor,
         request_id: request_id,
         request: content,
         request_bytes: canonical,
         request_digest: hash(canonical),
         decision_id: decision_id,
         decided_at: at,
         choice: choice,
         observations: native,
         repeat_id: if(choice["decision"] == "repeat", do: digest([decision_id, "repeat"]))
       }}
    else
      false -> {:error, :invalid_review}
      {:error, _} = error -> error
      _ -> {:error, :invalid_review}
    end
  end

  def plan(_, _, _, _, _), do: {:error, :invalid_review}

  defp validate_choice(source, choice) do
    allowed = ~w(decision note ranges metrics event_id acknowledged)
    metrics = Map.get(choice, "metrics", [])

    valid =
      Enum.all?(Map.keys(choice), &(&1 in allowed)) and
        text?(Map.get(choice, "note", ""), 2000, true) and is_list(metrics) and
        case choice["decision"] do
          d when d in ["reject", "repeat"] ->
            metrics == [] and
              (d != "repeat" or source.kind == :acquisition)

          "accept" ->
            source.kind == :manual and metrics == [] and
              Evidence.validate(source.body) == :ok

          "accept_metrics" ->
            source.kind == :acquisition and source.body["profile"] == "plx_spot_check" and
              Enum.sort(metrics) in [["pulse_rate"], ["spo2"], ["pulse_rate", "spo2"]] and
              Enum.any?(
                source.body["inventory"],
                &(&1["event"]["event_id"] == choice["event_id"])
              )

          d when d in ["complete", "partial"] ->
            source.kind == :acquisition and
              source.body["profile"] in ["paired_exam", "browser_microphone"] and metrics == [] and
              valid_ranges?(source.body, choice["ranges"]) and
              if(d == "complete",
                do: source.body["defects"] == [],
                else:
                  source.body["defects"] != [] and
                    choice["acknowledged"] == source.body["defects"] and
                    Map.get(choice, "note", "") != ""
              )

          _ ->
            false
        end

    if valid, do: :ok, else: {:error, :invalid_review}
  end

  def valid_ranges?(manifest, ranges) when is_list(ranges) and length(ranges) in 1..256 do
    Enum.all?(ranges, fn
      %{"stream" => name, "first" => first, "end" => ending} = range when map_size(range) == 3 ->
        with {:ok, a} <- counter(first),
             {:ok, b} <- counter(ending),
             true <- a < b,
             %{"index" => index} <- manifest["streams"][name] do
          segments = Enum.drop_while(index["segments"], &(uint(&1["end_sample"]) <= a))
          spans = index["spans"] || []

          covers?(segments, a, b, nil) and
            not Enum.any?(spans, fn span ->
              span["code"] in ["source_gap", "unaccounted_loss"] and
                uint(span["first_sample"]) < b and uint(span["end_sample"]) > a
            end)
        else
          _ -> false
        end

      _ ->
        false
    end)
  end

  def valid_ranges?(_, _), do: false

  defp covers?(_, a, b, _) when a >= b, do: true

  defp covers?([segment | rest], a, b, epoch) do
    first = uint(segment["first_sample"])
    ending = uint(segment["end_sample"])

    first <= a and a < ending and (is_nil(epoch) or segment["config_epoch"] == epoch) and
      covers?(rest, ending, b, segment["config_epoch"])
  end

  defp covers?(_, _, _, _), do: false

  defp observations(%{kind: :manual, body: body}, %{"decision" => "accept"}, _actor, at),
    do:
      {:ok,
       [
         Map.merge(body, %{
           "selection" => "manual:pulse_rate",
           "issued" => DateTime.to_iso8601(at),
           "export_required" => true
         })
       ]}

  defp observations(source, %{"decision" => "accept_metrics"} = choice, _actor, at) do
    event =
      Enum.find_value(source.body["inventory"], fn row ->
        if row["event"]["event_id"] == choice["event_id"], do: row["event"]
      end)

    Enum.reduce_while(Enum.sort(choice["metrics"]), {:ok, []}, fn code, {:ok, acc} ->
      case DeviceMeasurement.derived(
             event,
             code,
             source.id,
             source.body["principal"],
             DateTime.to_iso8601(at)
           ) do
        {:ok, native} ->
          {:cont,
           {:ok,
            acc ++
              [
                Map.merge(native, %{
                  "selection" => event["event_id"] <> ":" <> code,
                  "export_required" => true
                })
              ]}}

        _ ->
          {:halt, {:error, :ineligible_metric}}
      end
    end)
  end

  defp observations(_, _, _, _), do: {:ok, []}

  def counter(s) when is_binary(s) and byte_size(s) in 1..19 do
    if Regex.match?(~r/\A(?:0|[1-9][0-9]*)\z/, s) and
         String.to_integer(s) <= 9_223_372_036_854_775_807,
       do: {:ok, String.to_integer(s)},
       else: {:error, :invalid_counter}
  end

  def counter(_), do: {:error, :invalid_counter}

  defp uint(s) do
    case counter(s) do
      {:ok, n} -> n
      _ -> -1
    end
  end

  defp identifier?(s), do: is_binary(s) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/, s)
  defp digest?(s), do: is_binary(s) and Regex.match?(~r/\A[0-9a-f]{64}\z/, s)

  defp text?(s, max, empty \\ false),
    do: is_binary(s) and String.valid?(s) and byte_size(s) <= max and (empty or byte_size(s) > 0)

  defp digest(value), do: value |> MedEx.CanonicalJSON.encode() |> hash()
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
