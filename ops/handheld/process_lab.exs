defmodule MedFabric.Acceptance.ProcessLab do
  @moduledoc false
  # This script owns only the subprocess groups it created. Output stays in the
  # private lab, and every wait (including cleanup) has a monotonic deadline.
  def init(directory, deadline) do
    Process.put({__MODULE__, :directory}, directory)
    Process.put({__MODULE__, :deadline}, System.monotonic_time(:millisecond) + deadline)
    Process.put({__MODULE__, :children}, [])
    Process.put({__MODULE__, :statuses}, %{})
    Process.put({__MODULE__, :interrupted}, false)
    owner = self()

    for signal <- [:sigterm] do
      {:ok, _handler_id} =
        System.trap_signal(signal, {__MODULE__, signal}, fn ->
          send(owner, :mf_lab_interrupt)
          :ok
        end)
    end
  end

  def launch!(name, executable, args, cwd, env) do
    drain()
    children = children()
    number = length(children) + 1
    directory = Process.get({__MODULE__, :directory})
    log = Path.join([directory, "logs", "#{number}-#{name}.log"])
    pidfile = log <> ".pid"
    executable = System.find_executable(executable) || raise("Missing prerequisite #{executable}")
    setsid = System.find_executable("setsid") || raise("Missing setsid")
    shell = System.find_executable("sh") || raise("Missing sh")
    # A noninteractive supervisor shell remains outside the child's session.
    # Its asynchronous child is not a process-group leader, so setsid can
    # exec without forking. Shell wait preserves normal exit statuses and
    # reports signal termination as 128 + signal.
    supervisor = ~S(setsid=$1; shift; "$setsid" "$@" & child=$!; wait "$child"; exit "$?")

    command =
      "umask 077; printf '%s\\n' \"$$\" > \"$1\"; log=$2; shift 2; exec \"$@\" >\"$log\" 2>&1 </dev/null"

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args,
         [
           "-c",
           supervisor,
           "lab-supervisor",
           setsid,
           shell,
           "-c",
           command,
           "lab",
           pidfile,
           log,
           executable | args
         ]},
        {:env, port_env(env)}
      ])

    child = %{name: name, port: port, log: log, pidfile: pidfile}
    Process.put({__MODULE__, :children}, [child | children])
    # A fast command may exit before the next poll, but must have written PID.
    pid =
      wait!(
        fn ->
          case File.read(pidfile) do
            {:ok, value} ->
              case Integer.parse(String.trim(value)) do
                {pid, ""} when pid > 1 -> pid
                _ -> false
              end

            _ ->
              false
          end
        end,
        5_000,
        nil,
        "#{name} session creation"
      )

    if pid <= 1, do: raise("Unsafe process group identity")
    child = Map.put(child, :pid, pid)
    Process.put({__MODULE__, :children}, [child | children])
    child
  end

  defp port_env(env) do
    Map.merge(Map.new(System.get_env(), fn {key, _} -> {key, false} end), env)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key),
       if(value == false or is_nil(value), do: false, else: String.to_charlist(value))}
    end)
  end

  def run!(name, executable, args, cwd, env, timeout \\ 180_000) do
    child = launch!(name, executable, args, cwd, env)
    await_success!(child, timeout)
    child
  end

  def await_success!(child, timeout) do
    code = await!(child, timeout)
    unless code == 0, do: raise("#{child.name} exited #{code}; see #{Path.basename(child.log)}")
    :ok
  end

  def await!(child, timeout) do
    wait!(
      fn ->
        case status(child) do
          nil -> false
          code -> {:done, code}
        end
      end,
      timeout,
      nil,
      "#{child.name} exit"
    )
    |> elem(1)
  end

  def wait!(fun, timeout, child \\ nil, label \\ "readiness/evidence") do
    deadline =
      min(
        System.monotonic_time(:millisecond) + timeout,
        Process.get({__MODULE__, :deadline}, :infinity)
      )

    poll!(fun, deadline, child, label)
  end

  defp poll!(fun, deadline, child, label) do
    drain()
    if Process.get({__MODULE__, :interrupted}), do: raise("Acceptance interrupted")
    if child && status(child) != nil, do: raise("#{child.name} exited before #{label}")
    if System.monotonic_time(:millisecond) >= deadline, do: raise("Deadline expired: #{label}")

    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        Process.sleep(50)
        poll!(fun, deadline, child, label)
    end
  end

  def status(child) do
    drain()
    Map.get(Process.get({__MODULE__, :statuses}, %{}), child.port)
  end

  defp drain do
    receive do
      :mf_lab_interrupt ->
        Process.put({__MODULE__, :interrupted}, true)
        drain()

      {port, {:exit_status, status}} when is_port(port) ->
        Process.put(
          {__MODULE__, :statuses},
          Map.put(Process.get({__MODULE__, :statuses}, %{}), port, status)
        )

        drain()

      {port, {:data, _bytes}} when is_port(port) ->
        drain()

      {:EXIT, port, _reason} when is_port(port) ->
        drain()
    after
      0 -> :ok
    end
  end

  def kill!(child) do
    unless status(child) == nil, do: raise("#{child.name} exited before deliberate fault")
    signal!(child, "KILL")

    unless bounded_exit(child, 10_000) == 137,
      do: raise("#{child.name} did not report SIGKILL exit 137")

    :ok
  end

  def stop!(nil, _signal), do: :ok

  def stop!(child, signal) do
    if status(child) == nil do
      signal!(child, signal)

      case bounded_exit(child, 8_000) do
        nil ->
          signal!(child, "KILL")
          bounded_exit(child, 2_000) || raise("Failed to stop #{child.name}")

        code ->
          code
      end
    else
      status(child)
    end
  end

  defp signal!(child, signal) do
    # The session ID comes from our private pidfile; a live Port is required.
    # A normal completed command cannot be signalled using a stale PID.
    if status(child) == nil do
      case System.cmd("kill", ["-#{signal}", "--", "-#{child.pid}"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, _} -> unless status(child) != nil, do: raise("Could not signal #{child.name}")
      end
    end
  end

  defp bounded_exit(child, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_exit(child, deadline)
  end

  defp do_exit(child, deadline) do
    case status(child) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: nil,
          else:
            (
              Process.sleep(25)
              do_exit(child, deadline)
            )

      code ->
        code
    end
  end

  def children, do: Process.get({__MODULE__, :children}, [])

  def close! do
    failures =
      Enum.flat_map(children(), fn child ->
        try do
          if Map.has_key?(child, :pid), do: stop!(child, "TERM"), else: Port.close(child.port)
          []
        rescue
          _ -> [child.name]
        end
      end)

    for signal <- [:sigterm], do: System.untrap_signal(signal, {__MODULE__, signal})
    if failures != [], do: raise("Failed to clean up: #{Enum.join(failures, ", ")}")
    :ok
  end

  def evidence do
    Enum.map(Enum.reverse(children()), fn child ->
      %{name: child.name, pid: child[:pid], exit: status(child), log: Path.basename(child.log)}
    end)
  end
end
