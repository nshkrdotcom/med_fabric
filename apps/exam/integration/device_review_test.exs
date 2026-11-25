defmodule MedFabric.Exam.DeviceReviewTest do
  use ExUnit.Case, async: false

  alias MedFabric.Exam.DeviceReviews
  alias MedFabric.Store.{DeviceSessions, Encounters, MeasurementEvents, Postgres}
  alias DeviceSessions, as: S

  # This is a database transaction test. The separate process suite proves the
  # transport and immutable-file boundary before these records can be installed.
  setup do
    dir = Path.join(System.tmp_dir!(), "device-review-#{System.unique_integer([:positive])}")
    old = Application.get_env(:mf_exam, :lab)
    Application.put_env(:mf_exam, :lab, %{artifact_dir: dir})

    on_exit(fn ->
      if old,
        do: Application.put_env(:mf_exam, :lab, old),
        else: Application.delete_env(:mf_exam, :lab)

      File.rm_rf!(dir)
    end)

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
            Task.async(fn ->
              DeviceReviews.review_verified(c.enc, c.bind.id, c.actor, digest, choice)
            end)

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
             DeviceReviews.review_verified(c.enc, c.bind.id, c.actor, digest, %{
               choice
               | "metrics" => ["spo2"]
             })

    assert {:error, :review_changed} =
             DeviceReviews.review_verified(c.enc, c.bind.id, "other-clinician", digest, choice)

    assert {:error, :review_changed} =
             DeviceReviews.review_verified(
               c.enc,
               c.bind.id,
               c.actor,
               String.duplicate("0", 64),
               choice
             )
  end

  test "failure of the second selected metric rolls back the first, review, acceptance and outbox",
       c do
    # PLXS SFLOAT NaN is source evidence, never a numeric pulse value.
    {digest, choice} = seal_fixture(c, 0x07FF)

    assert {:error, :ineligible_metric} =
             DeviceReviews.review_verified(c.enc, c.bind.id, c.actor, digest, choice)

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
             DeviceReviews.review_verified(c.enc, c.bind.id, c.actor, digest, %{
               choice
               | "metrics" => ["spo2"]
             })

    assert [[1]] = derived_count(c)
    assert [[1]] = outbox_count(c)
  end

  test "a corrupt manifest cannot commit a decision or export intent", c do
    {digest, choice} = seal_fixture(c, 72)
    path = Path.join(MedFabric.Exam.DeviceManifest.root(c.bind.id), "manifest.mej1")
    File.write!(path, "corrupt")

    assert {:error, :unverified_manifest} =
             DeviceReviews.review_verified(c.enc, c.bind.id, c.actor, digest, choice)

    assert [[0]] = outbox_count(c)
  end

  test "frame and gap capacity return the same verified terminal receipt on reopen", c do
    S.rows(c.db, "UPDATE acquisitions SET state='interrupted' WHERE id=$1", [c.bind.id])
    assert :ok = S.authorize(c.enc, c.bind.device, "paired_exam", "fixture", c.actor)
    start_supervised!({Registry, keys: :unique, name: MedFabric.Exam.DeviceRegistry})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Exam.Captures})

    alias MedEx.Serialization
    alias MedEx.Wire.FrameV1
    alias MedFabric.Exam.DeviceIngress
    alias MedFabric.ExamWeb.DeviceSocket

    id = c.bind.id <> "-paired"

    descriptors =
      Map.new(["audio", "ecg"], fn name ->
        spec = %MedEx.StreamSpec{
          acquisition_id: id,
          source_ref: c.bind.device,
          boot_id: "boot-a",
          stream_id: name,
          source_epoch: 0,
          descriptor_ref: String.duplicate("0", 64),
          modality: "medex:synthetic",
          encoding: :s16le,
          sample_rate: {1, 1},
          channels: [%{id: "single", label: "Single", unit: :unknown, calibration: :unknown}],
          capabilities: %{
            encodings: [:s16le],
            max_frame_samples: 4,
            max_payload_bytes: 8,
            commands: [],
            replay: :durable_spool
          }
        }

        {name, Serialization.to_map(%{spec | descriptor_ref: Serialization.descriptor_ref(spec)})}
      end)

    assert {:ok, bind} = S.reserve(c.bind.device, c.enc, id, "paired_exam", "boot-a", descriptors)

    for {name, number} <- [{"audio", 1}, {"ecg", 2}] do
      digest = descriptors[name]["descriptor_ref"]
      assert {:ok, ingress, _} = DeviceIngress.open(bind, name, digest)
      writer = :sys.get_state(ingress).writer
      :sys.replace_state(writer, &put_in(&1.limits.duration_seconds, 2))

      frame = %FrameV1{
        stream_number: number,
        source_epoch: 0,
        config_epoch: 0,
        sequence: 0,
        first_sample: 0,
        sample_count: 1,
        payload: <<0, 0>>
      }

      state = %{kind: :stream, bind: bind, stream: name, writer: ingress, pending: false}

      state =
        Enum.reduce(0..1, state, fn q, state ->
          epoch = if number == 1, do: q, else: 0

          {:ok, raw} =
            FrameV1.encode(%{frame | sequence: q, first_sample: q, config_epoch: epoch})

          assert {:push, {:text, _}, pending} =
                   DeviceSocket.handle_in({raw, [opcode: :binary]}, state)

          assert_receive :checkpoint
          assert {:push, {:text, _}, state} = DeviceSocket.handle_info(:checkpoint, pending)
          state
        end)

      [[prior_receipt]] =
        S.rows(
          c.db,
          "SELECT receipt FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2",
          [id, name]
        )

      input =
        if number == 1 do
          {:ok, raw} = FrameV1.encode(%{frame | sequence: 2, first_sample: 2})
          {raw, [opcode: :binary]}
        else
          gap = %{
            "schema" => "medex.device.v1",
            "type" => "gap",
            "id" => "capacity-gap",
            "first" => "2",
            "end" => "3",
            "first_sequence" => "2",
            "next_sequence" => "3",
            "irreversible" => true,
            "cause" => "synthetic"
          }

          {Jason.encode!(gap), [opcode: :text]}
        end

      assert {:push, {:text, reply}, %{writer: nil, pending: false}} =
               DeviceSocket.handle_in(input, state)

      refute_received :checkpoint
      assert %{"type" => "stream_finished"} = wire = Jason.decode!(reply)
      assert {:ok, receipt} = Serialization.receipt(Map.drop(wire, ["schema", "type"]))
      assert {receipt.durable_sequence, receipt.durable_sample} == {2, 2}
      assert {:error, {:sealed, ^receipt}} = DeviceIngress.open(bind, name, digest)

      assert [[index]] =
               S.rows(c.db, "SELECT sealed_index FROM stream_attempts WHERE fence=$1", [
                 receipt.fence
               ])

      assert index["terminal"] == "interrupted"
      assert index["terminal_reason"] == "duration_limit"

      # Model the durable terminal after a lost SQL commit.
      S.rows(
        c.db,
        "UPDATE stream_attempts SET sealed_index=NULL,index_digest=NULL,receipt=$2 WHERE fence=$1",
        [receipt.fence, prior_receipt]
      )

      assert {:error, {:sealed, ^receipt}} = DeviceIngress.open(bind, name, digest)
    end

    assert {:ok, digest} = MedFabric.Exam.DeviceManifest.finish(bind, %{})
    hash = S.hash(<<0, 0>>)
    workflow = MedFabric.Exam.DeviceWorkflow

    assert {:ok, _, %{first_sample: 0}, <<0, 0>>} =
             workflow.segment(c.enc, id, digest, "ecg", "0", hash)

    assert {:ok, _, %{first_sample: 1}, <<0, 0>>} =
             workflow.segment(c.enc, id, digest, "ecg", "1", hash)

    assert {:error, :unverified_segment} = workflow.segment(c.enc, id, digest, "ecg", hash)

    secret = "synthetic-router-fixture"

    Application.put_env(:mf_exam, :lab, %{
      artifact_dir: MedFabric.Exam.lab().artifact_dir,
      proxy_secret: secret,
      local?: false,
      encounters: %{c.enc => %{"clinician_actor" => c.actor, "patient_actor" => "patient"}}
    })

    path = "/encounters/#{c.enc}/devices/#{id}/segment/ecg/1/#{hash}?revision=#{digest}"

    request = fn path, actor, role, token ->
      conn = fn ->
        Plug.Test.conn(:get, path)
        |> Plug.Conn.put_req_header("x-exam-proxy-token", token)
        |> Plug.Conn.put_req_header("x-exam-actor", actor)
      end

      response =
        conn.()
        |> Plug.Test.init_test_session(%{
          lab_encounter: c.enc,
          exam_actor: actor,
          exam_role: role
        })
        |> MedFabric.ExamWeb.Endpoint.call([])

      if response.status == 303 do
        conn.()
        |> Plug.Test.recycle_cookies(response)
        |> MedFabric.ExamWeb.Endpoint.call([])
      else
        response
      end
    end

    assert %{status: 200, resp_body: body} = request.(path, c.actor, "clinician", secret)
    assert body =~ "samples 1–2"
    assert %{status: 403} = request.(path, c.actor, "clinician", "incorrect")
    assert request.(path, "patient", "patient", secret).status in [403, 404]

    other_path = String.replace(path, "/encounters/#{c.enc}/", "/encounters/unknown/")
    assert %{status: 404} = request.(other_path, c.actor, "clinician", secret)

    manifest = Path.join(MedFabric.Exam.DeviceManifest.root(id), "manifest.mej1")
    defects = manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("defects")

    range = fn stream, first, ending ->
      %{"stream" => stream, "first" => first, "end" => ending}
    end

    review = fn ranges ->
      DeviceReviews.review_verified(c.enc, id, c.actor, digest, %{
        "decision" => "partial",
        "note" => "Fixture review",
        "acknowledged" => defects,
        "ranges" => ranges,
        "metrics" => []
      })
    end

    assert {:error, :invalid_review} = review.([range.("audio", "0", "2")])
    assert {:error, :invalid_review} = review.([range.("ecg", "00", "2")])
    assert {:ok, :ok} = review.([range.("ecg", "0", "2"), range.("audio", "1", "2")])

    S.rows(c.db, "UPDATE encounters SET closed_at=now() WHERE id=$1", [c.enc])
    assert %{status: 403} = request.(path, c.actor, "clinician", secret)
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
      "streams" => %{},
      "inventory" => [%{"event" => event, "fingerprint" => fingerprint}],
      "defects" => []
    }

    digest = S.hash(MedEx.CanonicalJSON.encode(manifest))

    root = MedFabric.Exam.DeviceManifest.root(c.bind.id)
    File.mkdir_p!(root)
    File.write!(Path.join(root, "manifest.mej1"), MedEx.CanonicalJSON.encode(manifest))

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
