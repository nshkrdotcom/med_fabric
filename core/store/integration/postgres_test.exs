defmodule MedFabric.Store.PostgresTest do
  use ExUnit.Case, async: false

  alias MedFabric.Domain.Encounter
  alias MedFabric.Store.Postgres


  setup do
    url = System.fetch_env!("DATABASE_URL")
    server = start_supervised!({Postgres, url: url, pool_size: 2})
    assert :ok = Postgres.migrate(server)

    encounter_id = "db-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    {:ok, encounter} =
      Encounter.new(encounter_id) |> Encounter.request_acquisition("acq", "session")

    encounter =
      Encounter.apply_fact(
        encounter,
        {:capture_completed,
         %{
           encounter_ref: encounter_id,
           acquisition_id: "acq",
           session_id: "session",
           artifact_sha256: "recording-digest",
           interval_ms: {0, 1_000},
           continuity: :observed_continuous
         }}
      )

    {:ok, _updated, acceptance} =
      Encounter.accept_acquisition(encounter, "acq", "recording-digest", "reviewer")

    %{
      url: url,
      server: server,
      acceptance: acceptance,
      observation_id: acceptance.observation.observation_id,
      provenance: %{
        source_kind: "fixture",
        source_ref: "clip.wav",
        artifact_path: "/test/clip.wav"
      }
    }
  end

  test "rolls back observation if provenance insert fails", ctx do
    assert {:error, %Postgrex.Error{}} =
             Postgres.commit_acceptance(ctx.server, ctx.acceptance, nil)

    assert row_counts(ctx) == [0, 0, 0]

    assert {:ok, :committed, _} =
             Postgres.commit_acceptance(ctx.server, ctx.acceptance, ctx.provenance)

    assert row_counts(ctx) == [1, 1, 1]
  end

  test "concurrent requests and a lost reply preserve one committed record after reconnect",
       ctx do
    attempts =
      for _ <- 1..2 do
        Task.async(fn ->
          Postgres.commit_acceptance(ctx.server, ctx.acceptance, ctx.provenance)
        end)
      end

    assert [
             {:ok, :already_committed, record},
             {:ok, :committed, record}
           ] = attempts |> Task.await_many() |> Enum.sort()

    assert row_counts(ctx) == [1, 1, 1]
    stop_supervised!(Postgres)
    reopened = start_supervised!({Postgres, url: ctx.url})
    assert {:ok, ^record} = Postgres.fetch_record(reopened, ctx.observation_id)

    assert {:ok, :already_committed, ^record} =
             Postgres.commit_acceptance(reopened, ctx.acceptance, ctx.provenance)

    assert record.provenance.artifact_path == "/test/clip.wav"
  end

  test "delivered is terminal and a different digest cannot replace acceptance", ctx do
    assert {:ok, :committed, record} =
             Postgres.commit_acceptance(ctx.server, ctx.acceptance, ctx.provenance)

    intent_id = record.outbox.intent_id

    assert {:ok, %{status: :retry_scheduled}} =
             Postgres.mark_delivery_failed(ctx.server, intent_id, :timeout, 4_000)

    assert {:ok, %{status: :delivered, attempts: 2, next_retry_at_ms: nil} = delivered} =
             Postgres.mark_delivered(ctx.server, intent_id, "Observation/1")

    assert {:ok, ^delivered} = Postgres.mark_delivered(ctx.server, intent_id, "Observation/1")

    assert {:ok, ^delivered} =
             Postgres.mark_delivery_failed(ctx.server, intent_id, :late_failure, 5_000)

    conflicting =
      ctx.acceptance
      |> put_in([:observation, :artifact_sha256], "another-digest")
      |> put_in([:export_intent, :artifact_sha256], "another-digest")

    assert {:error, :conflicting_observation} =
             Postgres.commit_acceptance(ctx.server, conflicting, ctx.provenance)
  end

  defp row_counts(ctx) do
    %{rows: [counts]} =
      Postgrex.query!(
        ctx.server,
        """
        SELECT (SELECT count(*) FROM accepted_observations WHERE observation_id = $1),
               (SELECT count(*) FROM artifact_provenance WHERE observation_id = $1),
               (SELECT count(*) FROM fhir_export_outbox WHERE observation_id = $1)
        """,
        [ctx.observation_id]
      )

    counts
  end
end
