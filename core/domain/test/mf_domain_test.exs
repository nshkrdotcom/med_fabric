defmodule MedFabric.Domain.NativeReviewTest do
  use ExUnit.Case, async: true
  alias MedFabric.Domain.{Evidence, NativeValue, Review}
  @at ~U[2026-11-24 12:00:00Z]
  defp source(body),
    do: %{
      kind: :manual,
      id: "manual_one",
      encounter: "exam_one",
      digest: MedEx.Serialization.digest(body),
      body: body,
      verified: true
    }

  test "manual zero is native evidence and acceptance creates a native observation without any FHIR input" do
    assert {:ok, body} = Evidence.pulse_rate(0, @at, "clinician")
    assert :ok = Evidence.validate(body)

    assert {:ok, plan} =
             Review.plan(source(body), "clinician", "request_one", %{"decision" => "accept"}, @at)

    assert [observation] = plan.observations
    assert observation["value"] == %{"mantissa" => "0", "exponent" => "0"}
    assert observation["actor"] == "clinician"
    assert observation["export_required"]
    assert observation["source_digest"] == source(body).digest
    assert observation["digest"] == MedEx.Serialization.digest(Map.delete(observation, "digest"))
    refute Map.has_key?(observation, "resourceType")
  end

  test "stable request identity excludes generated commit time; changed choice changes content" do
    {:ok, body} = Evidence.pulse_rate(72, @at, "clinician")

    {:ok, one} =
      Review.plan(
        source(body),
        "clinician",
        "request_one",
        %{"decision" => "accept", "note" => ""},
        @at
      )

    {:ok, two} =
      Review.plan(
        source(body),
        "clinician",
        "request_one",
        %{"decision" => "accept", "note" => ""},
        DateTime.add(@at, 1)
      )

    assert one.request == two.request
    assert one.decision_id == two.decision_id
    assert hd(one.observations)["id"] == hd(two.observations)["id"]

    {:ok, changed} =
      Review.plan(source(body), "clinician", "request_one", %{"decision" => "reject"}, @at)

    refute changed.request == one.request
    assert changed.observations == []
  end

  test "manual validation is independent of constructor and rejects malformed unit, provenance or timestamps" do
    {:ok, body} = Evidence.pulse_rate(76, @at, "clinician")

    for invalid <- [
          Map.put(body, "unit", "bpm"),
          Map.put(body, "kind", "ecg"),
          Map.put(body, "effective_at", nil),
          Map.put(body, "injected", true),
          put_in(body, ["provenance", "actor"], ""),
          put_in(body, ["provenance", "kind"], "device"),
          put_in(body, ["value", "mantissa"], "-1")
        ] do
      assert {:error, _} = Evidence.validate(invalid)

      assert {:error, _} =
               Review.plan(
                 source(invalid),
                 "clinician",
                 "request",
                 %{"decision" => "accept"},
                 @at
               )
    end

    assert {:error, _} = Review.plan(%{}, "clinician", "request", %{}, @at)
  end

  test "native exact decimals use clinical eligibility, not external representation limits" do
    assert NativeValue.eligible?("pulse_rate", %{
             "mantissa" => "9223372036854775807",
             "exponent" => "0"
           })

    assert NativeValue.eligible?("spo2", %{"mantissa" => "1000", "exponent" => "-1"})
    refute NativeValue.eligible?("spo2", %{"mantissa" => "1001", "exponent" => "-1"})
    refute NativeValue.eligible?("pulse_rate", %{"mantissa" => "-1", "exponent" => "0"})

    for value <- [
          %{"mantissa" => "-0", "exponent" => "0"},
          %{"mantissa" => "01", "exponent" => "0"},
          %{"mantissa" => 1, "exponent" => "0"},
          %{"mantissa" => "1", "exponent" => "19"}
        ] do
      assert {:error, _} = NativeValue.parse(value)
    end
  end

  test "waveform ranges require actual contiguous coverage in one configuration epoch and no source gap" do
    a = %{"first_sample" => "0", "end_sample" => "10", "config_epoch" => "0"}
    b = %{"first_sample" => "10", "end_sample" => "20", "config_epoch" => "0"}
    manifest = %{"streams" => %{"audio" => %{"index" => %{"segments" => [a, b], "spans" => []}}}}
    range = [%{"stream" => "audio", "first" => "2", "end" => "18"}]
    assert Review.valid_ranges?(manifest, range)

    refute Review.valid_ranges?(
             put_in(manifest, ["streams", "audio", "index", "segments"], [
               a,
               Map.put(b, "config_epoch", "1")
             ]),
             range
           )

    refute Review.valid_ranges?(
             put_in(manifest, ["streams", "audio", "index", "spans"], [
               %{"code" => "source_gap", "first_sample" => "8", "end_sample" => "12"}
             ]),
             range
           )

    refute Review.valid_ranges?(manifest, [%{"stream" => "audio", "first" => "0", "end" => "21"}])

    refute Review.valid_ranges?(manifest, [%{"stream" => "audio", "first" => "-1", "end" => "20"}])
  end
end
