defmodule MedFabric.Exam.Application do
  @moduledoc false
  use Application

  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Postgres, Records}

  @impl true
  def start(_type, _args) do
    children = [{Phoenix.PubSub, name: MedFabric.Exam.PubSub}]

    lab_children =
      case Application.get_env(:mf_exam, :lab) do
        nil ->
          []

        lab ->
          [
            {Postgres, url: lab.database_url, name: Postgres},
            %{id: :schema, start: {__MODULE__, :schema, []}},
            {Registry, keys: :unique, name: MedFabric.Exam.ActiveCapture},
            {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Exam.Captures}
          ]
      end

    Supervisor.start_link(children ++ lab_children ++ [Endpoint],
      strategy: :one_for_one,
      name: MedFabric.Exam.Supervisor
    )
  end

  def schema do
    lab = MedFabric.Exam.lab()

    with {:ok, :ok} <- Postgres.migrate(),
         :ok <- Records.open(Postgres, lab.encounter_id, lab.patient_actor, lab.clinician_actor) do
      :ignore
    else
      {:error, reason} -> {:error, {:schema_unavailable, reason}}
    end
  end
end
