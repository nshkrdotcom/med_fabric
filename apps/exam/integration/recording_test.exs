defmodule MedFabric.Exam.RecordingTest do
  use ExUnit.Case, async: false
  alias MedFabric.Exam
  alias MedFabric.Exam.{Artifact, Context, Recordings}
  alias MedFabric.ExamWeb.PCMSocket
  alias MedFabric.Store.{Encounters, Postgres, Records}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    encounter = "recording-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    db = start_supervised!({Postgres, url: System.fetch_env!("DATABASE_URL"), pool_size: 4})
    captures = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    {:ok, :ok} = Postgres.migrate(db)

    context = %Context{
      db: db,
      captures: captures,
      pubsub: pubsub,
      artifact_dir: dir,
      encounter_ids: [encounter]
    }

    {:ok, :ok} =
      Encounters.open(db, %{
        "exam" => encounter,
        "patient_actor" => "patient",
        "clinician_actor" => "clinician",
        "destination" => "http://localhost/fhir",
        "patient_ref" => "Patient/" <> encounter,
        "encounter_ref" => "Encounter/" <> encounter
      })

    %{encounter: encounter, context: context}
  end

  test "writer installed its WAV but the recording update was interrupted", %{
    encounter: encounter,
    context: context
  } do
    {owner, mon, id, _capture} = socket_owner(encounter, "Contact input", context)

    assert {:ok, %{first_received_at: first_frame}} = Records.pending(context.db, encounter)

    # Let the real socket finish through fsync/link. PostgreSQL then holds the
    # readiness update at the row lock until we cancel that specific backend.
    assert {:ok, :ok} =
             Postgrex.transaction(context.db, fn tx ->
               %{rows: [[locker]]} =
                 Postgrex.query!(
                   tx,
                   """
                   SELECT pg_backend_pid() FROM acquisitions WHERE encounter_id=$1 AND id=$2 FOR UPDATE
                   """,
                   [encounter, id]
                 )

               send(owner, :finish)
               blocked = blocked_writer(tx, locker, 300)
               %{rows: [[true]]} = Postgrex.query!(tx, "SELECT pg_cancel_backend($1)", [blocked])
               assert_receive {:socket_result, ^id, {:stop, :normal, 1011, _, _}}, 5000
               Process.exit(owner, :kill)
               assert_receive {:DOWN, ^mon, :process, ^owner, :killed}
               :ok
             end)

    assert :ok = Recordings.recover(%{context | encounter_ids: []})
    assert {:ok, "recording"} = Records.recording_status(context.db, encounter, id)
    assert :ok = Recordings.recover(context)
    assert {:ok, "ready"} = Recordings.status(encounter, id, context)
    assert {:ok, [%{id: ^id, evidence: evidence}]} = Records.list(context.db, encounter)
    assert evidence["provenance"]["input"]["label"] == "Contact input"
    assert evidence["provenance"]["actor"] == "patient"
    assert evidence["sample_count"] == 2
    assert evidence["effective_at"] == DateTime.to_iso8601(first_frame)
    assert evidence["continuity"] == "observed_continuous"
    assert :ok = Artifact.verify(context.artifact_dir, id, evidence)
  end

  test "a lost ready reply preserves one outcome per ID even for identical bytes", %{
    encounter: encounter,
    context: context
  } do
    ids =
      for label <- ["USB stethoscope", "Laptop microphone"] do
        {owner, mon, id, _capture} = socket_owner(encounter, label, context)
        send(owner, :finish)
        assert_receive {:socket_result, ^id, {:stop, :normal, 1000, {:text, "ready"}, _}}, 5000
        # WebSock has yet to send the callback's reply.
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^mon, :process, ^owner, :killed}
        assert {:ok, "ready"} = Recordings.status(encounter, id, context)
        id
      end

    assert :ok = Recordings.recover(context)

    evidence =
      Enum.map(ids, fn id ->
        assert {:ok, %{evidence: row}} = Records.get(context.db, encounter, id)
        row
      end)

    assert Enum.map(evidence, & &1["provenance"]["input"]["label"]) == [
             "USB stethoscope",
             "Laptop microphone"
           ]

    assert length(Enum.uniq_by(evidence, & &1["artifact_key"])) == 2
    assert length(Enum.uniq_by(evidence, & &1["file_sha256"])) == 1
    assert {:ok, rows} = Records.list(context.db, encounter)
    assert length(rows) == 2
  end

  test "reconciliation preserves a live writer, then interrupts its abandoned partial", c do
    assert {:error, :capture_unavailable} = Recordings.admit(c.encounter, "clinician", c.context)
    Phoenix.PubSub.subscribe(c.context.pubsub, "preview:" <> c.encounter)
    {owner, mon, id, capture} = socket_owner(c.encounter, "USB", c.context)
    assert_receive {:capture_started, ^capture}
    assert [{_, ^capture, _, _}] = DynamicSupervisor.which_children(c.context.captures)
    writer_ref = Process.monitor(capture)
    assert :ok = Recordings.recover(c.context)
    assert {:ok, "recording"} = Recordings.status(c.encounter, id, c.context)
    assert {:error, :capture_unavailable} = Recordings.admit(c.encounter, "patient", c.context)

    # Hard process death bypasses both terminate callbacks, leaving the .part.
    Process.exit(capture, :kill)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^writer_ref, :process, ^capture, :killed}
    assert_receive {:DOWN, ^mon, :process, ^owner, :killed}
    assert {:ok, "interrupted"} = Recordings.status(c.encounter, id, c.context)
    assert [] == File.ls!(Path.join(c.tmp_dir, id))
    assert {:ok, []} = Records.list(c.context.db, c.encounter)
  end

  test "closing an unfinished socket releases its writer and interrupts the reservation", c do
    assert {:push, {:text, _}, state} =
             PCMSocket.init(%{encounter: c.encounter, actor: "patient", context: c.context})

    assert :ok = PCMSocket.terminate(:normal, state)
    assert is_nil(Recordings.active(c.encounter))
    assert {:ok, "interrupted"} = Records.recording_status(c.context.db, c.encounter, state.id)
  end

  @tag timeout: 180_000
  test "a 30-minute WAV can be accepted during concurrent range playback", c do
    id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    dir = Path.join(c.tmp_dir, id)
    :ok = Artifact.create_directory(c.tmp_dir, id)
    :ok = Records.reserve(c.context.db, c.encounter, id, "patient")

    :ok =
      Records.first_frame(
        c.context.db,
        c.encounter,
        id,
        %{"label" => "Reference"},
        DateTime.utc_now(:microsecond)
      )

    samples = 48_000 * 60 * 30
    bytes = samples * 2

    header =
      <<"RIFF", bytes + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        48_000::little-32, 96_000::little-32, 2::little-16, 16::little-16, "data",
        bytes::little-32>>

    path = Path.join(dir, "fixture")
    {:ok, fd} = :file.open(path, [:write, :raw, :binary])
    :ok = :file.write(fd, header)
    :ok = :file.pwrite(fd, 44 + bytes - 1, <<5>>)
    :ok = :file.close(fd)

    digest =
      File.stream!(path, 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    File.rename!(path, Path.join(dir, digest <> ".wav"))
    assert {:ok, "ready"} = Recordings.status(c.encounter, id, c.context)
    assert {:ok, %{evidence: evidence}} = Records.get(c.context.db, c.encounter, id)
    assert evidence["sample_count"] == samples

    accept = Task.async(fn -> Exam.accept(c.encounter, id, "clinician", c.context) end)

    players =
      for offset <- [1, 4] do
        Task.async(fn ->
          conn =
            Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("range", "bytes=-#{offset}")

          sent = Artifact.serve(conn, c.tmp_dir, id, evidence)
          assert sent.status == 206
          assert sent.resp_body == :binary.copy(<<0>>, offset - 1) <> <<5>>
        end)
      end

    assert :ok = Task.await(accept, 120_000)
    Enum.each(players, &Task.await(&1, 120_000))
    assert {:ok, %{actor: "clinician"}} = Records.get(c.context.db, c.encounter, id)
  end

  defp socket_owner(encounter, label, context) do
    caller = self()

    {owner, mon} =
      spawn_monitor(fn ->
        {:push, {:text, message}, state} =
          PCMSocket.init(%{encounter: encounter, actor: "patient", context: context})

        %{"acquisition_id" => id} = Jason.decode!(message)

        {:ok, state} =
          PCMSocket.handle_in({Jason.encode!(%{source: %{label: label}}), [opcode: :text]}, state)

        {:push, {:text, "ack"}, state} =
          PCMSocket.handle_in({<<0::64, 3, 2, 1, 0>>, [opcode: :binary]}, state)

        send(caller, {:admitted, self(), id, state.capture})

        receive do
          :finish ->
            result = PCMSocket.handle_in({"finish", [opcode: :text]}, state)
            send(caller, {:socket_result, id, result})
        end

        receive do
          :close -> :ok
        end
      end)

    assert_receive {:admitted, ^owner, id, capture}, 5000
    {owner, mon, id, capture}
  end

  defp blocked_writer(_tx, _locker, 0),
    do: flunk("WAV readiness update did not reach the database")

  defp blocked_writer(tx, locker, remaining) do
    case Postgrex.query!(
           tx,
           """
           SELECT pid FROM pg_stat_activity WHERE $1::integer = ANY(pg_blocking_pids(pid))
           """,
           [locker]
         ).rows do
      [[pid]] ->
        pid

      [] ->
        Process.sleep(10)
        blocked_writer(tx, locker, remaining - 1)
    end
  end
end
