defmodule MedFabric.Exam.Application do
  @moduledoc false
  use Application

  alias MedFabric.Exam
  alias MedFabric.Exam.{ClockObservations, DeviceManifest, PreviewGateway, Recordings}
  alias MedFabric.ExamWeb.Endpoint
  alias MedFabric.Store.{Encounters, Postgres}

  @impl true
  def start(_type, _args) do
    ClockObservations.initialize_host_generation()

    children = [{Phoenix.PubSub, name: MedFabric.Exam.PubSub}]
    lab = Application.get_env(:mf_exam, :lab)

    lab_children =
      case lab do
        nil ->
          []

        lab ->
          device =
            if lab[:device_enabled] do
              :ets.new(:mf_live_ecg, [:named_table, :set, :public, write_concurrency: true])

              [
                {MedFabric.Exam.DeviceRootLock, lab.artifact_dir},
                {Registry, keys: :unique, name: MedFabric.Exam.DeviceRegistry}
              ]
            else
              []
            end

          device ++
            [
              {Postgres, url: lab.database_url, name: Postgres, pool_size: 12},
              %{id: :schema, start: {__MODULE__, :schema, []}},
              {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Exam.Captures}
            ] ++ if(lab[:device_enabled], do: [MedFabric.Exam.DeviceExpiry], else: [])
      end

    preview =
      with %{device_enabled: true} <- lab,
           %{} = sidecar <- Application.get_env(:mf_exam, :sidecar) do
        [{PreviewGateway, sidecar}]
      else
        _ -> []
      end

    Supervisor.start_link(children ++ lab_children ++ [Endpoint] ++ preview,
      # Keep the root guard before its writers and the disposable relay last.
      strategy: :rest_for_one,
      name: MedFabric.Exam.Supervisor
    )
  end

  def schema do
    lab = Exam.lab()

    with {:ok, :ok} <- Postgres.migrate(),
         :ok <- open_encounters(lab.encounters),
         :ok <- Recordings.recover(),
         :ok <- recover_devices(lab) do
      :ignore
    else
      {:error, reason} -> {:error, {:schema_unavailable, reason}}
    end
  end

  defp recover_devices(%{device_enabled: true}), do: DeviceManifest.recover()
  defp recover_devices(_), do: :ok

  defp open_encounters(encounters) do
    Enum.reduce_while(encounters, :ok, fn {_id, entry}, :ok ->
      case Encounters.open(Postgres, entry) do
        {:ok, :ok} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
