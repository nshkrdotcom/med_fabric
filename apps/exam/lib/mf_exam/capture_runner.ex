defmodule MedFabric.Exam.CaptureRunner do
  @moduledoc "Admits one fixture capture. The task is linked to this owner."
  use GenServer
  alias MedFabric.Exam
  alias MedFabric.Store.Postgres
  alias MedRTC.WavCapture

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def start, do: GenServer.call(__MODULE__, :start)
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(config), do: {:ok, %{config: config, task: nil, error: nil}}

  @impl true
  def handle_call(:status, _, state), do: {:reply, {state.task != nil, state.error}, state}

  def handle_call(:start, _, %{task: nil, config: config} = state) do
    case Postgres.fetch(Postgres, Exam.key(config)) do
      {:ok, nil} ->
        task = Task.async(fn -> capture(config) end)
        Exam.announce(config)
        {:reply, :ok, %{state | task: task.ref, error: nil}}

      {:ok, _} ->
        {:reply, {:error, :already_recorded}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(:start, _, state), do: {:reply, {:error, :capture_active}, state}

  @impl true
  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    Exam.announce(state.config)
    {:noreply, %{state | task: nil, error: result != :ok}}
  end

  defp capture(config) do
    {enc, acq} = key = Exam.key(config)

    with :ok <- File.mkdir_p(config.artifact_dir),
         {:ok, artifact} <-
           WavCapture.record(
             Path.join(config.fixture_dir, "2530_AV.wav"),
             Path.join(config.fixture_dir, "2530_AV.opus"),
             config.artifact_dir,
             acquisition_id: acq,
             on_preview_frame: fn index, frame ->
               Phoenix.PubSub.broadcast(
                 MedFabric.Exam.PubSub,
                 "preview:" <> enc,
                 {:preview_frame, index, frame}
               )
             end
           ) do
      Postgres.ready(Postgres, key, Exam.session_id(enc), artifact, "2530_AV.wav", config.refs)
    end
  end
end
