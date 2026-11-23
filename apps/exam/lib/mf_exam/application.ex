defmodule MedFabric.Exam.Application do
  @moduledoc false
  use Application

  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Encounters, Postgres}

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
         :ok <- open_encounters(lab.encounters),
         :ok <- MedFabric.Exam.Recordings.recover() do
      :ignore
    else
      {:error, reason} -> {:error, {:schema_unavailable, reason}}
    end
  end

  defp open_encounters(encounters) do
    Enum.reduce_while(encounters, :ok, fn {_id, entry}, :ok ->
      case Encounters.open(Postgres, entry) do
        {:ok, :ok} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
