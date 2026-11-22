defmodule MedFabric.Exam.CaptureRunner do
  @moduledoc "Admits one fixture capture. The task is linked to this owner."
  use GenServer
  alias MedFabric.Exam
  alias MedFabric.Store.Postgres
  alias MedRTC.WavCapture

  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)
  def start, do: call(:start)

  def status do
    case call(:status) do
      {:error, :capture_unavailable} -> {false, true}
      status -> status
    end
  end

  defp call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, {reason, _call} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :capture_unavailable}
  end

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    {:ok, %{config: config, task: nil, error: nil}}
  end

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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: ref} = state) do
    Exam.announce(state.config)
    {:noreply, %{state | task: nil, error: true}}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  defp capture(config) do
    {enc, acq} = key = Exam.key(config)
    generation = System.unique_integer([:positive, :monotonic])

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
                 {:preview_frame, generation, index, frame}
               )
             end
           ) do
      Postgres.ready(Postgres, key, Exam.session_id(enc), artifact, "2530_AV.wav", config.refs)
    end
  end
end
