defmodule MedFabric.Store.OutboxStoreTest do
  use ExUnit.Case, async: true

  alias MedFabric.Domain.Encounter
  alias MedFabric.Store.OutboxStore

  defp build_acceptance do
    {:ok, enc} = Encounter.new("enc_store_1") |> Encounter.request_acquisition("acq_1")

    enc =
      Encounter.apply_fact(
        enc,
        {:capture_completed,
         %{
           acquisition_id: "acq_1",
           session_id: "sess_1",
           artifact_sha256: "sha_store_1",
           interval_ms: {200, 1_200},
           continuity: :observed_continuous
         }}
      )

    {:ok, _enc, acceptance} = Encounter.accept_acquisition(enc, "acq_1", "sha_store_1", "clin_1")
    acceptance
  end

  test "retry after crash before commit converges on one observation and one outbox intent" do
    {:ok, store} = OutboxStore.start_link()
    acceptance = build_acceptance()
    provenance = %{source_kind: :physionet_circor, source_ref: "2530_AV.wav", sample_rate_hz: 4_000}

    assert {:error, :db_connection_lost_before_commit} =
             OutboxStore.commit_acceptance(store, acceptance, provenance,
               before_commit: fn -> {:error, :db_connection_lost_before_commit} end
             )

    assert OutboxStore.list_observations(store) == []
    assert OutboxStore.list_outbox(store) == []

    assert {:ok, :committed, record} = OutboxStore.commit_acceptance(store, acceptance, provenance)
    assert record.observation.observation_id == "obs:enc_store_1:acq_1"
    assert record.outbox.status == :pending
    assert record.outbox.external_id == "urn:med_fabric:observation:obs:enc_store_1:acq_1"
    assert length(OutboxStore.list_observations(store)) == 1
    assert length(OutboxStore.list_outbox(store)) == 1
  end

  test "retry after crash after commit (lost reply) converges idempotently without duplicating records" do
    {:ok, store} = OutboxStore.start_link()
    acceptance = build_acceptance()
    provenance = %{source_kind: :physionet_circor, source_ref: "2530_AV.wav", sample_rate_hz: 4_000}

    assert_raise RuntimeError, "caller_crashed_before_reply", fn ->
      OutboxStore.commit_acceptance(store, acceptance, provenance,
        after_commit: fn _record -> raise "caller_crashed_before_reply" end
      )
    end

    # The first transaction succeeded atomically before the caller crashed
    assert length(OutboxStore.list_observations(store)) == 1
    assert length(OutboxStore.list_outbox(store)) == 1

    # Retrying the same acceptance converges idempotently on the single committed record
    assert {:ok, :already_committed, record} =
             OutboxStore.commit_acceptance(store, acceptance, provenance)

    assert record.observation.observation_id == "obs:enc_store_1:acq_1"
    assert length(OutboxStore.list_observations(store)) == 1
    assert length(OutboxStore.list_outbox(store)) == 1
  end

  test "conflicting digest for an existing observation_id fails closed and outbox tracks retry to delivered" do
    {:ok, store} = OutboxStore.start_link()
    acceptance = build_acceptance()
    provenance = %{source_kind: :synthetic, source_ref: "test_pcm"}

    {:ok, :committed, record} = OutboxStore.commit_acceptance(store, acceptance, provenance)

    tampered = put_in(acceptance.observation.artifact_sha256, "sha_tampered")

    assert {:error, :conflicting_observation_digest} =
             OutboxStore.commit_acceptance(store, tampered, provenance)

    intent_id = record.outbox.intent_id

    {:ok, failed} =
      OutboxStore.mark_delivery_failed(store, intent_id, :transport_timeout, 5_000)

    assert failed.status == :retry_scheduled
    assert failed.attempts == 1
    assert failed.next_retry_at_ms == 5_000

    {:ok, delivered} = OutboxStore.mark_delivered(store, intent_id, "Observation/hapi-101")
    assert delivered.status == :delivered
    assert delivered.attempts == 2
    assert delivered.remote_ref == "Observation/hapi-101"
    assert {:ok, ^delivered} = OutboxStore.fetch_outbox(store, intent_id)
  end
end
