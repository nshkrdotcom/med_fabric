defmodule MedFabric.Exam.DeviceReviewTest do
  use ExUnit.Case, async: false

  alias MedFabric.Exam.DeviceReviews
  alias MedFabric.Store.{DeviceSessions, Encounters, MeasurementEvents, Postgres}
  alias DeviceSessions, as: S

  # This is a database transaction test. The separate process suite proves the
  # transport and immutable-file boundary before these records can be installed.
  setup do
    db =
      start_supervised!(
        {Postgres, url: System.fetch_env!("DATABASE_URL"), name: Postgres, pool_size: 6}
      )

    assert {:ok, :ok} = Postgres.migrate(db)
    suffix = Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    enc = "review-" <> suffix
    device = "handheld-" <> suffix
    actor = "clinician-" <> suffix

    assert {:ok, :ok} =
             Encounters.open(db, %{
               "exam" => enc,
               "patient_actor" => "patient-" <> suffix,
               "clinician_actor" => actor,
               "destination" => "http://example.invalid/fhir",
               "patient_ref" => "Patient/" <> suffix,
               "encounter_ref" => "Encounter/" <> suffix
             })

    assert S.enroll(device, String.duplicate(suffix, 3))
    assert :ok = S.authorize(enc, device, "plx_spot_check", "index-finger", actor)

    assert {:ok, bind} =
             S.reserve(device, enc, "collection-" <> suffix, "plx_spot_check", "boot-a", %{})

    %{db: db, enc: enc, actor: actor, bind: bind}
  end

  test "concurrent acceptance of both metrics creates one decision and exactly two outbox intents",
       c do
    {digest, choice} = seal_fixture(c, 72)

    tasks =
      for _ <- 1..2,
          do:
            Task.async(fn -> DeviceReviews.review(c.enc, c.bind.id, c.actor, digest, choice) end)

    assert Enum.map(tasks, &Task.await(&1, 10_000)) == [{:ok, :ok}, {:ok, :ok}]

    assert [[1]] =
             S.rows(c.db, "SELECT count(*) FROM device_reviews WHERE acquisition_id=$1", [
               c.bind.id
             ])

    assert [[2]] = derived_count(c)
    assert [[2]] = outbox_count(c)

    rows =
      S.rows(
        c.db,
        """
        SELECT a.evidence, d.resource, jsonb_typeof(d.resource #> '{valueQuantity,value}')
        FROM acquisitions a
        JOIN outbox_deliveries d ON (d.encounter_id, d.acquisition_id) = (a.encounter_id, a.id)
        WHERE a.parent_acquisition_id = $1
        ORDER BY a.evidence->>'kind'
        """,
        [c.bind.id]
      )

    for [evidence, resource, value_type] <- rows do
      assert value_type == "number"
      assert evidence["provenance"]["simulated"]
      assert evidence["source_event_id"] == "measurement-one"
      assert resource["device"]["reference"] == "Device/synthetic-plx"
      assert resource["effectiveDateTime"] == "2020-01-02T03:04:05Z"
      assert resource["issued"] != resource["effectiveDateTime"]
    end

    [_, [_, oxygen, _]] = rows
    assert Decimal.equal?(oxygen["valueQuantity"]["value"], Decimal.new("97.2"))

    assert {:error, :review_conflict} =
             DeviceReviews.review(c.enc, c.bind.id, c.actor, digest, %{
               choice
               | "metrics" => ["spo2"]
             })

    assert {:error, :review_changed} =
             DeviceReviews.review(c.enc, c.bind.id, "other-clinician", digest, choice)

    assert {:error, :review_changed} =
             DeviceReviews.review(c.enc, c.bind.id, c.actor, String.duplicate("0", 64), choice)
  end

  test "failure of the second selected metric rolls back the first, review, acceptance and outbox",
       c do
    # PLXS SFLOAT NaN is source evidence, never a numeric pulse value.
    {digest, choice} = seal_fixture(c, 0x07FF)

    assert {:error, :ineligible_metric} =
             DeviceReviews.review(c.enc, c.bind.id, c.actor, digest, choice)

    assert [[0]] = derived_count(c)
    assert [[0]] = outbox_count(c)

    assert [[0]] =
             S.rows(c.db, "SELECT count(*) FROM device_reviews WHERE acquisition_id=$1", [
               c.bind.id
             ])

    assert [[1]] =
             S.rows(c.db, "SELECT count(*) FROM measurement_events WHERE acquisition_id=$1", [
               c.bind.id
             ])

    # The retained valid saturation remains separately reviewable after rollback.
    assert {:ok, :ok} =
             DeviceReviews.review(c.enc, c.bind.id, c.actor, digest, %{
               choice
               | "metrics" => ["spo2"]
             })

    assert [[1]] = derived_count(c)
    assert [[1]] = outbox_count(c)
  end

  defp seal_fixture(c, pulse_word) do
    raw =
      <<7, 0xF3CC::little-16, pulse_word::little-16, 2020::little-16, 1, 2, 3, 4, 5,
        1280::little-16, 0::little-24>>

    pulse =
      if pulse_word == 0x07FF,
        do: %{"missing" => "nan"},
        else: %{"mantissa" => to_string(pulse_word), "exponent" => "0"}

    event = %{
      "raw" => Base.encode64(raw),
      "event_id" => "measurement-one",
      "gateway_sequence" => "0",
      "source" => "synthetic-plx",
      "simulated" => true,
      "phase" => "completed",
      "metrics" => %{"spo2" => %{"mantissa" => "972", "exponent" => "-1"}, "pulse_rate" => pulse},
      "source_status" => %{"measurement" => "1280", "device" => "0"},
      "measured_at" => "2020-01-02T03:04:05Z",
      "time_basis" => "qualified_fixture_utc"
    }

    assert :ok = MedFabric.Domain.DeviceMeasurement.validate(event)
    fingerprint = S.hash(MedEx.CanonicalJSON.encode(event))
    assert {:ok, :durable} = MeasurementEvents.put(c.bind, event, fingerprint)

    manifest = %{
      "acquisition" => c.bind.id,
      "profile" => "plx_spot_check",
      "simulated" => true,
      "inventory" => [%{"event" => event, "fingerprint" => fingerprint}],
      "defects" => []
    }

    digest = S.hash(MedEx.CanonicalJSON.encode(manifest))

    S.rows(c.db, "INSERT INTO device_manifests(acquisition_id,digest,body) VALUES($1,$2,$3)", [
      c.bind.id,
      digest,
      manifest
    ])

    evidence = %{
      "kind" => "plx_spot_check",
      "manifest_digest" => digest,
      "provenance" => %{"kind" => "simulated_device", "simulated" => true}
    }

    S.rows(
      c.db,
      "UPDATE acquisitions SET state='ready',evidence=$3,producer=NULL WHERE encounter_id=$1 AND id=$2",
      [c.enc, c.bind.id, evidence]
    )

    S.rows(c.db, "UPDATE device_sessions SET phase='sealed',manifest_digest=$2 WHERE id=$1", [
      c.bind.id,
      digest
    ])

    {digest,
     %{
       "decision" => "accept_metrics",
       "event_id" => "measurement-one",
       "metrics" => ["spo2", "pulse_rate"],
       "note" => "Synthetic engineering fixture reviewed"
     }}
  end

  defp derived_count(c),
    do:
      S.rows(c.db, "SELECT count(*) FROM acquisitions WHERE parent_acquisition_id=$1", [c.bind.id])

  defp outbox_count(c),
    do:
      S.rows(
        c.db,
        "SELECT count(*) FROM outbox_deliveries d JOIN acquisitions a ON (a.encounter_id,a.id)=(d.encounter_id,d.acquisition_id) WHERE a.parent_acquisition_id=$1",
        [c.bind.id]
      )
end
