defmodule MedFabric.Exam do
  @moduledoc "Composition of common acquisition, native review and independently durable delivery."
  alias MedFabric.Domain.{Evidence, Review}
  alias MedFabric.Exam.Context
  alias MedFabric.Store.{Records, Deliveries, AcquisitionSessions}
  def lab, do: Application.fetch_env!(:mf_exam, :lab)

  def context do
    lab = lab()

    %Context{
      db: MedFabric.Exam.Database,
      artifact_dir: lab.artifact_dir,
      root_owner: Process.whereis(MedFabric.Exam.RootOwner),
      registry: MedFabric.Exam.AcquisitionRegistry,
      writers: MedFabric.Exam.Writers,
      pubsub: MedFabric.Exam.PubSub
    }
  end

  def member?(enc, actor, role, db \\ MedFabric.Exam.Database)

  def member?(enc, actor, role, db) when role in [:patient, "patient"],
    do: Records.member?(db, enc, actor, :patient)

  def member?(enc, actor, role, db) when role in [:clinician, "clinician"],
    do: Records.member?(db, enc, actor, :clinician)

  def member?(_, _, _, _), do: false

  def announce(enc, context \\ context()),
    do: Phoenix.PubSub.broadcast(context.pubsub, "exam:" <> enc, :exam_changed)

  def pulse(enc, actor, value, context \\ context()) do
    with {:ok, evidence} <- Evidence.pulse_rate(value, DateTime.utc_now(), actor),
         {:ok, id} <-
           Records.put_manual(context.db, enc, AcquisitionSessions.nonce(), actor, evidence) do
      announce(enc, context)
      {:ok, id}
    end
  end

  def accept(enc, id, actor, request_id, context \\ context()) do
    with {:ok, source} <- Records.manual(context.db, enc, id, actor),
         {:ok, plan} <-
           Review.plan(
             source,
             actor,
             request_id,
             %{"decision" => "accept", "note" => ""},
             DateTime.utc_now()
           ),
         {:ok, outcome} <- Records.accept_plan(context.db, plan) do
      announce(enc, context)
      {:ok, outcome}
    end
  end

  def deliver(enc, id, actor, context \\ context()) do
    with {:ok, :ok} <- Deliveries.authorize(context.db, id, enc, actor),
         {:ok, intent} <- Deliveries.get(context.db, id) do
      if intent.status in ["blocked", "retryable", "unresolved"],
        do: Deliveries.remediate(context.db, id, actor),
        else: {:ok, intent.status}
    end
  end
end
