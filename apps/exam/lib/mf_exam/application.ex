defmodule MedFabric.Exam.Application do
  @moduledoc false
  use Application

  alias MedFabric.Exam.Demo
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.Postgres

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
            {Task.Supervisor, name: MedFabric.Exam.CaptureTasks},
            {Demo, lab}
          ]
      end

    Supervisor.start_link(children ++ lab_children ++ [Endpoint],
      strategy: :one_for_one,
      name: MedFabric.Exam.Supervisor
    )
  end
end
