Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.Exam.BackgroundIsolationTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias MedFabric.Domain.{Evidence, Review}
  alias MedFabric.Exam.{AcquisitionExpiry, AcquisitionIngress, DeliveryWorker, DeviceRootLock, IntegrationFixtures}
  alias MedFabric.Store.{AcquisitionSessions, Deliveries, Postgres, Records}
  alias MedFabric.ExamWeb.Endpoint
  setup context, do: IntegrationFixtures.trusted_tmp(context)

  setup %{tmp_dir: root} do
    # A separate disposable database lets the real Application run its exact
    # ownership/schema/recovery/listener order without altering retained data.
    url = System.fetch_env!("DATABASE_URL")
    database = "mf_worker_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, admin} = Postgres.start_link(url: url)
    Postgrex.query!(admin, "CREATE DATABASE " <> database, [])
    GenServer.stop(admin)
    previous = Application.get_env(:mf_exam, :lab)
    :ok = Application.stop(:mf_exam)
    database_url = %{URI.parse(url) | path: "/" <> database} |> URI.to_string()

    on_exit(fn ->
      Application.stop(:mf_exam)
      if is_nil(previous), do: Application.delete_env(:mf_exam, :lab), else: Application.put_env(:mf_exam, :lab, previous)
      {:ok, cleanup} = Postgres.start_link(url: url)
      Postgrex.query!(cleanup, "DROP DATABASE " <> database <> " WITH (FORCE)", [])
      GenServer.stop(cleanup)
      {:ok, _} = Application.ensure_all_started(:mf_exam)
    end)

    Application.put_env(:mf_exam, :lab, %{
      artifact_dir: root,
      deployment_uuid: "00000000-0000-4000-8000-000000000002",
      database_url: database_url,
      encounters: %{"encounter" => %{"exam" => "encounter", "patient_actor" => "patient", "clinician_actor" => "clinician"}}
    })

    {:ok, _} = Application.ensure_all_started(:mf_exam)
    context = MedFabric.Exam.context()
    background = child(MedFabric.Exam.Supervisor, :background)
    %{context: context, background: background}
  end

  test "isolated delivery and expiry failures preserve Endpoint and the admitted capture", c do
    context = c.context
    {bind, spec, _, _} = IntegrationFixtures.browser(context)
    {:ok, ingress, _} = AcquisitionIngress.open(context, bind, "audio", spec.descriptor_ref)
    endpoint = Process.whereis(Endpoint)
    expiry = child(c.background, AcquisitionExpiry)
    delivery = child(c.background, DeliveryWorker)

    kill_and_restart(c.background, DeliveryWorker, delivery)
    assert child(c.background, AcquisitionExpiry) == expiry
    assert Process.whereis(Endpoint) == endpoint
    assert Process.alive?(ingress)
    assert DeviceRootLock.current_connection?(context.root_owner, {bind.id, "audio"}, bind.connection)
    assert {:ok, _} = AcquisitionIngress.call(ingress, {:frame, IntegrationFixtures.frame()})
    assert {:ok, %{receipt: %{durable_sample: 2}}} = AcquisitionIngress.call(ingress, :checkpoint)

    delivery = child(c.background, DeliveryWorker)
    kill_and_restart(c.background, AcquisitionExpiry, expiry)
    assert child(c.background, DeliveryWorker) == delivery
    assert Process.whereis(Endpoint) == endpoint
    assert {:ok, _} = AcquisitionIngress.call(ingress, {:frame, IntegrationFixtures.frame(1, 2)})
    assert {:ok, %{receipt: %{durable_sample: 4}}} = AcquisitionIngress.call(ingress, :checkpoint)
  end

  test "core database loss still restarts and fences dependent capture", c do
    {bind, spec, _, _} = IntegrationFixtures.browser(c.context)
    {:ok, ingress, _} = AcquisitionIngress.open(c.context, bind, "audio", spec.descriptor_ref)
    endpoint = Process.whereis(Endpoint)
    ingress_ref = Process.monitor(ingress)
    endpoint_ref = Process.monitor(endpoint)
    database = Process.whereis(MedFabric.Exam.Database)
    Process.exit(database, :kill)
    assert_receive {:DOWN, ^ingress_ref, :process, ^ingress, _}, 10_000
    assert_receive {:DOWN, ^endpoint_ref, :process, ^endpoint, _}, 10_000
    eventually(fn -> is_pid(Process.whereis(Endpoint)) and Process.whereis(Endpoint) != endpoint end)
    refute DeviceRootLock.current_connection?(c.context.root_owner, {bind.id, "audio"}, bind.connection)
  end

  test "transient polling errors and more than one bad due row cannot starve later work", c do
    worker = child(c.background, DeliveryWorker)
    :ok = :sys.suspend(worker)
    healthy = native_intent(c.context, "healthy")

    for n <- 1..5 do
      id = native_intent(c.context, "bad_#{n}")
      # A deterministic database failure during preparation must leave the
      # pending row and its absent effect history intact while later rows run.
      AcquisitionSessions.rows(c.context.db,
        "UPDATE outbox_deliveries SET next_due_at=clock_timestamp()-interval '1 minute' WHERE id=$1", [id])
      AcquisitionSessions.rows(c.context.db,
        "CREATE OR REPLACE FUNCTION reject_pending_#{n}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.id='" <> id <> "' AND NEW.status='blocked' THEN RAISE EXCEPTION 'synthetic_private_row_#{n}'; END IF; RETURN NEW; END $$", [])
      AcquisitionSessions.rows(c.context.db,
        "CREATE TRIGGER reject_pending_#{n} BEFORE UPDATE ON outbox_deliveries FOR EACH ROW EXECUTE FUNCTION reject_pending_#{n}()", [])
    end

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    :sys.replace_state(worker, fn context -> %{context | db: dead} end)
    log = capture_log(fn ->
      :ok = :sys.resume(worker)
      Process.sleep(600)
      assert Process.alive?(worker)
      :sys.replace_state(worker, fn _ -> c.context end)
      eventually(fn -> match?({:ok, %{status: "blocked"}}, Deliveries.get(c.context.db, healthy)) end)
    end)

    assert log =~ "delivery_poll_failed"
    assert log =~ "delivery_item_outcome_unknown"
    refute log =~ "synthetic_private_row"
    assert child(c.background, DeliveryWorker) == worker
    assert [[0]] = AcquisitionSessions.rows(c.context.db, "SELECT count(*) FROM delivery_attempts", [])
    assert [[5]] = AcquisitionSessions.rows(c.context.db,
      "SELECT count(*) FROM outbox_deliveries WHERE status='pending' AND next_due_at>clock_timestamp() AND executions=0", [])
  end

  defp native_intent(context, suffix) do
    {:ok, body} = Evidence.pulse_rate(76, ~U[2026-11-24 12:00:00Z], "clinician")
    {:ok, _} = Records.put_manual(context.db, "encounter", "manual_" <> suffix, "clinician", body)
    {:ok, source} = Records.manual(context.db, "encounter", "manual_" <> suffix, "clinician")
    {:ok, plan} = Review.plan(source, "clinician", "review_" <> suffix, %{"decision" => "accept"}, DateTime.utc_now())
    {:ok, %{observations: [id]}} = Records.accept_plan(context.db, plan)
    id
  end

  defp child(supervisor, id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  defp kill_and_restart(supervisor, id, pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    eventually(fn -> is_pid(child(supervisor, id)) and child(supervisor, id) != pid end)
  end

  defp eventually(check, attempts \\ 300)
  defp eventually(_, 0), do: flunk("host did not reach the expected state")
  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
