defmodule MedFabric.Exam.DeviceRootLock do
  @moduledoc "Linux local-process lock. Deployment requires one service-managed BEAM per capture root."
  use GenServer
  def start_link(root), do: GenServer.start_link(__MODULE__, root)

  def init(root) do
    File.mkdir_p!(root)
    path = Path.join(root, "device-writer.lock")

    flock =
      System.find_executable("flock") ||
        raise "flock is required for exclusive capture root ownership"

    port =
      Port.open({:spawn_executable, String.to_charlist(flock)}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args,
         Enum.map(
           ["--nonblock", "--no-fork", path, "sh", "-c", "echo locked && exec cat >/dev/null"],
           &String.to_charlist/1
         )}
      ])

    receive do
      {^port, {:data, "locked\n"}} -> {:ok, port}
      {^port, {:exit_status, _}} -> {:stop, :artifact_root_in_use}
    after
      5000 -> {:stop, :artifact_lock_timeout}
    end
  end

  def handle_info({port, {:exit_status, _}}, port) do
    # A lost fence invalidates every writer on this node. Do not reacquire it
    # around still-live children. The service manager can launch a fresh VM.
    System.halt(1)
    {:stop, :fence_lost, port}
  end

  def handle_info(_, port), do: {:noreply, port}

  def terminate(_, port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
