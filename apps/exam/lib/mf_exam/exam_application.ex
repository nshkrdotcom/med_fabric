defmodule MedFabric.Exam.Application do
  @moduledoc false
  use Application
  alias MedFabric.Exam
  alias MedFabric.Exam.{AcquisitionExpiry, AcquisitionManifest, ClockObservations, DeliveryWorker}
  alias MedFabric.Store.{AcquisitionSessions, Encounters, Postgres}
  @asset_revision "0.3.0"
  @asset_hashes %{
    "exam.js" => "0ace0894746932833484406d9a578e7f5ee1f3ee21a60b7ada33569c4edabdf2",
    "acquisition.js" => "260a1e618d115041bcab49a9c60939165ff90c22f029bcfb12cf9bb2681b0609",
    "acquisition_worklet.js" => "6fcb7dd5010a6b410d6a55fb4e189dbff07cec8bcb6a5e10fc65e43799f9610b"
  }

  def start(_type, _args) do
    :ok = MedFabric.Exam.LogPrivacy.install()
    ClockObservations.initialize_host_generation()

    case Application.get_env(:mf_exam, :lab) do
      nil ->
        if Application.get_env(:mf_exam, MedFabric.ExamWeb.Endpoint, [])[:server] == true,
          do: {:error, :runtime_configuration_required},
          else:
            Supervisor.start_link(
              [{Phoenix.PubSub, name: MedFabric.Exam.PubSub}, MedFabric.ExamWeb.Endpoint],
              strategy: :one_for_one,
              name: MedFabric.Exam.Supervisor
            )

      lab ->
        :ets.new(:mf_live_ecg, [:named_table, :set, :public, write_concurrency: true])

        children = [
          {Phoenix.PubSub, name: MedFabric.Exam.PubSub},
          {MedFabric.Exam.DeviceRootLock,
           [
             name: MedFabric.Exam.RootOwner,
             root: lab.artifact_dir,
             deployment_uuid: lab.deployment_uuid
           ]},
          {Postgres, url: lab.database_url, name: MedFabric.Exam.Database, pool_size: 12},
          %{id: :schema, start: {__MODULE__, :schema, []}},
          {Registry, keys: :unique, name: MedFabric.Exam.AcquisitionRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Exam.Writers},
          %{id: :recovery, start: {__MODULE__, :recover, []}},
          MedFabric.ExamWeb.Endpoint,
          %{id: :background, type: :supervisor, start: {__MODULE__, :background, []}}
        ]
        Supervisor.start_link(children,
          strategy: :rest_for_one,
          name: MedFabric.Exam.Supervisor
        )
    end
  end

  def schema do
    lab = Exam.lab()

    with :ok <- resources(),
         {:ok, :ok} <- Postgres.migrate(MedFabric.Exam.Database, lab.deployment_uuid),
         {:ok, %{recovery_state: "current"}} <- Postgres.identity(MedFabric.Exam.Database),
         :ok <- open_encounters(lab.encounters) do
      :ignore
    else
      _ -> {:error, :startup_validation_failed}
    end
  end

  def recover do
    case AcquisitionManifest.recover(Exam.context()) do
      :ok -> :ignore
      {:error, _} -> {:error, :startup_recovery_failed}
    end
  end

  def background(context \\ Exam.context(), sidecar \\ Application.get_env(:mf_exam, :sidecar)) do
    preview = if is_nil(sidecar), do: [], else: [{MedFabric.Exam.PreviewGateway, sidecar}]

    Supervisor.start_link([{AcquisitionExpiry, context}, {DeliveryWorker, context}] ++ preview,
      strategy: :one_for_one
    )
  end

  @doc false
  def resources(dir \\ Application.app_dir(:mf_exam, "priv/static")) do
    verified =
      to_string(Application.spec(:mf_exam, :vsn)) == @asset_revision and
        Enum.all?(@asset_hashes, fn {name, expected} ->
          path = Path.join(dir, name)

          with {:ok, %{type: :regular, size: size}} <- File.lstat(path),
               true <- size in 1..262_144,
               {:ok, bytes} <- File.read(path),
               true <- byte_size(bytes) == size do
            AcquisitionSessions.hash(bytes) == expected
          else
            _ -> false
          end
        end)

    if verified, do: :ok, else: {:error, :installed_assets_mismatch}
  end

  defp open_encounters(entries),
    do:
      Enum.reduce_while(entries, :ok, fn {_id, entry}, :ok ->
        case Encounters.open(MedFabric.Exam.Database, entry) do
          {:ok, :ok} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
end
