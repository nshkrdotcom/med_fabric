Code.require_file("support/fixtures.exs", __DIR__)
Code.require_file("support/measurement_fixture.exs", __DIR__)

defmodule MedFabric.Exam.CanonicalEventReviewTest do
  use ExUnit.Case, async: false

  alias MedFabric.Exam.{
    AcquisitionManifest,
    AcquisitionReviews,
    IntegrationFixtures,
    TestMeasurement
  }

  alias MedFabric.Store.{AcquisitionSessions, Deliveries, MeasurementEvents}

  setup context, do: IntegrationFixtures.trusted_tmp(context)

  test "canonical event-only evidence produces two atomic native observations and unprepared intents",
       %{tmp_dir: root} do
    c = IntegrationFixtures.context(root)
    {bind, _} = IntegrationFixtures.device(c, "plx_spot_check")
    event = TestMeasurement.event(bind.id, bind.principal, bind.boot)
    assert {:ok, one} = MeasurementEvents.put(c.db, bind, event)
    assert {:ok, ^one} = MeasurementEvents.put(c.db, bind, event)

    assert {:error, _} =
             MeasurementEvents.put(
               c.db,
               bind,
               put_in(event, ["metrics", "spo2"], ["value", "999", "-1", "%"])
             )

    entries = MeasurementEvents.inventory(c.db, bind.id)
    final = %{"count" => "1", "digest" => AcquisitionManifest.inventory_digest(entries)}
    assert {:ok, digest} = AcquisitionManifest.finish(c, bind, final)
    assert {:ok, ^digest} = AcquisitionManifest.finish(c, bind, final)

    choice = %{
      "decision" => "accept_metrics",
      "event_id" => event["event_id"],
      "metrics" => ["pulse_rate", "spo2"]
    }

    assert {:ok, result} =
             AcquisitionReviews.review(
               c,
               "encounter",
               bind.id,
               "clinician",
               digest,
               "review_one",
               choice
             )

    assert length(result.observations) == 2

    assert {:ok, ^result} =
             AcquisitionReviews.review(
               c,
               "encounter",
               bind.id,
               "clinician",
               digest,
               "review_one",
               choice
             )

    for id <- result.observations do
      assert {:ok, %{status: "pending", resource: nil, destination: nil}} =
               Deliveries.get(c.db, id)
    end

    assert {:error, :request_conflict} =
             AcquisitionReviews.review(
               c,
               "encounter",
               bind.id,
               "clinician",
               digest,
               "review_one",
               %{choice | "metrics" => ["spo2"]}
             )

    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM measurement_events", [])
  end

  test "negative pulse aborts both selected metrics without deleting canonical source evidence",
       %{tmp_dir: root} do
    c = IntegrationFixtures.context(root)
    {bind, _} = IntegrationFixtures.device(c, "plx_spot_check")
    event = TestMeasurement.event(bind.id, bind.principal, bind.boot, -1)
    assert {:ok, _} = MeasurementEvents.put(c.db, bind, event)
    entries = MeasurementEvents.inventory(c.db, bind.id)

    assert {:ok, digest} =
             AcquisitionManifest.finish(c, bind, %{
               "count" => "1",
               "digest" => AcquisitionManifest.inventory_digest(entries)
             })

    choice = %{
      "decision" => "accept_metrics",
      "event_id" => event["event_id"],
      "metrics" => ["pulse_rate", "spo2"]
    }

    assert {:error, :ineligible_metric} =
             AcquisitionReviews.review(
               c,
               "encounter",
               bind.id,
               "clinician",
               digest,
               "review_invalid",
               choice
             )

    for table <- ~w(reviews observations outbox_deliveries),
        do: assert([[0]] == AcquisitionSessions.rows(c.db, "SELECT count(*) FROM " <> table, []))

    assert [[1]] = AcquisitionSessions.rows(c.db, "SELECT count(*) FROM measurement_events", [])

    assert {:ok, %{observations: [_]}} =
             AcquisitionReviews.review(
               c,
               "encounter",
               bind.id,
               "clinician",
               digest,
               "review_spo2",
               %{choice | "metrics" => ["spo2"]}
             )
  end
end
