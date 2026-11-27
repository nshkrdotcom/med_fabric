defmodule MedFabric.Exam.DeviceRootLock do
  @moduledoc "Exclusive service-owned root, immutable deployment identity and local effect gates. Lock loss is fail-stop."
  use GenServer
  import Bitwise
  alias MedFabric.Exam.EffectiveUID
  alias MedFabric.Store.AcquisitionSessions

  def start_link(opts) do
    case GenServer.start_link(__MODULE__, {self(), opts}, name: Keyword.fetch!(opts, :name)) do
      {:error, {:shutdown, reason}} -> {:error, reason}
      result -> result
    end
  end

  def gate(pid, key), do: GenServer.call(pid, {:gate, key}, 5_000)
  def release(pid, key), do: GenServer.call(pid, {:release, key}, 5_000)
  def recover_gate(pid, key), do: GenServer.call(pid, {:recover_gate, key}, 5_000)
  def settle_gate(pid, key, prefix), do: GenServer.call(pid, {:settle_gate, key, prefix}, 5_000)
  def poison(pid, key), do: GenServer.call(pid, {:poison, key}, 5_000)

  def bind_connection(pid, key, connection, socket),
    do: GenServer.call(pid, {:bind_connection, key, connection, socket}, 5_000)

  def current_connection?(pid, key, connection),
    do: GenServer.call(pid, {:current_connection, key, connection}, 5_000)

  def invalidate_connection(pid, key),
    do: GenServer.call(pid, {:invalidate_connection, key}, 5_000)

  def init({caller, opts}) do
    case initialize(opts) do
      {:stop, reason} ->
        Process.unlink(caller)
        {:stop, {:shutdown, reason}}

      success ->
        success
    end
  end

  defp initialize(opts) do
    root = Path.expand(Keyword.fetch!(opts, :root))
    uuid = Keyword.fetch!(opts, :deployment_uuid)
    existed = File.exists?(root)

    with {:ok, uid} <- EffectiveUID.resolve(),
         :ok <- File.mkdir_p(root),
         :ok <- if(existed, do: :ok, else: File.chmod(root, 0o700)),
         :ok <- trusted_path(root, uid),
         {:ok, root_identity} <- root_identity(root),
         :ok <- identity(root, uuid),
         executable when is_binary(executable) <- System.find_executable("flock") do
      path = Path.join(root, "capture-service.lock")

      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
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
        {^port, {:data, "locked\n"}} ->
          if EffectiveUID.resolve() == {:ok, uid} and
               root_identity(root) == {:ok, root_identity} and trusted_path(root, uid) == :ok do
            {:ok,
             %{
               root: root,
               uuid: uuid,
               uid: uid,
               root_identity: root_identity,
               port: port,
               token: make_ref(),
               gates: %{},
               connections: %{}
             }}
          else
            if Port.info(port), do: Port.close(port)
            {:stop, :untrusted_artifact_root}
          end

        {^port, {:exit_status, _}} ->
          {:stop, :artifact_root_in_use}
      after
        5_000 ->
          if Port.info(port), do: Port.close(port)
          {:stop, :artifact_lock_timeout}
      end
    else
      {:error, reason} -> {:stop, reason}
      _ -> {:stop, :root_lock_unavailable}
    end
  end

  def handle_call({:med_ex_root_ownership, path}, _, s) do
    inside = Path.expand(path) == s.root or String.starts_with?(Path.expand(path), s.root <> "/")

    if inside and Port.info(s.port) != nil and EffectiveUID.resolve() == {:ok, s.uid} and
         root_identity(s.root) == {:ok, s.root_identity} and trusted_path(s.root, s.uid) == :ok,
       do: {:reply, {:ok, %{root: s.root, token: s.token}}, s},
       else: {:reply, {:error, :root_ownership_lost}, s}
  end

  def handle_call({:bind_connection, key, connection, socket}, {pid, _}, s) do
    case s.gates[key] do
      %{owner: ^pid, ref: gate_ref, poisoned: false} ->
        if s.connections[key], do: Process.demonitor(s.connections[key].ref, [:flush])

        {:reply, :ok,
         put_in(s.connections[key], %{
           connection: connection,
           gate_ref: gate_ref,
           socket: socket,
           ref: Process.monitor(socket)
         })}

      _ ->
        {:reply, {:error, :gate_owner_required}, s}
    end
  end

  def handle_call({:current_connection, key, connection}, _, s) do
    active =
      case s.connections[key] do
        %{connection: ^connection, socket: socket, gate_ref: gate_ref} ->
          Process.alive?(socket) and connection_gate_alive?(s.gates[key], gate_ref)

        _ ->
          false
      end

    {:reply, active, s}
  end

  def handle_call({:invalidate_connection, key}, {socket, _}, s) do
    case s.connections[key] do
      %{socket: ^socket, ref: ref} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{s | connections: Map.delete(s.connections, key)}}

      _ ->
        {:reply, :ok, s}
    end
  end

  def handle_call({:gate, key}, {pid, _}, s) do
    case s.gates[key] do
      nil ->
        if connection = s.connections[key], do: Process.demonitor(connection.ref, [:flush])
        s = %{s | connections: Map.delete(s.connections, key)}
        ref = Process.monitor(pid)
        {:reply, :ok, put_in(s.gates[key], %{owner: pid, ref: ref, poisoned: false})}

      %{owner: ^pid, poisoned: false} ->
        {:reply, :ok, s}

      %{poisoned: true} ->
        {:reply, {:error, :prior_effect_quiescence_required}, s}

      _ ->
        {:reply, {:error, :effect_in_flight}, s}
    end
  end

  def handle_call({:recover_gate, key}, {pid, _}, s) do
    case s.gates[key] do
      %{owner: owner, ref: ref, poisoned: true} ->
        if owner == pid or not Process.alive?(owner) do
          Process.demonitor(ref, [:flush])

          {:reply, :ok,
           put_in(s.gates[key], %{owner: pid, ref: Process.monitor(pid), poisoned: true})}
        else
          {:reply, {:error, :prior_owner_alive}, s}
        end

      _ ->
        {:reply, {:error, :recovery_not_required}, s}
    end
  end

  def handle_call(
        {:settle_gate, {id, name} = key, %MedEx.Storage.RecoveredPrefix{} = prefix},
        {pid, _},
        s
      ) do
    expected =
      Path.join([s.root, "acquisitions-v2", AcquisitionSessions.hash(id), name]) <>
        "/"

    proof = prefix.provenance

    case s.gates[key] do
      %{owner: ^pid, poisoned: true} = gate ->
        if verified_quiescence?(proof, s, prefix, expected) do
          {:reply, :ok, put_in(s.gates[key], %{gate | poisoned: false})}
        else
          {:reply, {:error, :unverified_quiescence}, s}
        end

      _ ->
        {:reply, {:error, :gate_owner_required}, s}
    end
  end

  def handle_call({:settle_gate, _, _}, _, s), do: {:reply, {:error, :unverified_quiescence}, s}

  def handle_call({:poison, key}, {pid, _}, s) do
    case s.gates[key] do
      %{owner: ^pid, ref: ref} = gate ->
        s = put_in(s.gates[key], %{gate | poisoned: true})
        {:reply, :ok, %{s | connections: drop_connections(s.connections, ref)}}

      _ ->
        {:reply, {:error, :gate_owner_required}, s}
    end
  end

  def handle_call({:release, key}, {pid, _}, s) do
    case s.gates[key] do
      %{owner: ^pid, ref: ref, poisoned: false} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{s | gates: Map.delete(s.gates, key)}}

      _ ->
        {:reply, {:error, :gate_owner_required}, s}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, s),
    do:
      {:noreply,
       %{
         s
         | connections: drop_connections(s.connections, ref),
           gates:
             Map.new(s.gates, fn {k, v} ->
               {k, if(v.ref == ref, do: %{v | poisoned: true}, else: v)}
             end)
       }}

  def handle_info({port, {:exit_status, _}}, %{port: port} = s) do
    System.halt(1)
    {:stop, :root_ownership_lost, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  # Explicit release precedes a normal terminal reply. An active gate must
  # still belong to this binding and have a live, unpoisoned owner.
  defp connection_gate_alive?(nil, _ref), do: true

  defp connection_gate_alive?(%{owner: owner, ref: ref, poisoned: false}, ref),
    do: Process.alive?(owner)

  defp connection_gate_alive?(_, _), do: false

  defp drop_connections(connections, ref) do
    Map.reject(connections, fn
      {_, %{ref: ^ref}} ->
        true

      {_, %{gate_ref: ^ref, ref: socket_ref}} ->
        Process.demonitor(socket_ref, [:flush])
        true

      _ ->
        false
    end)
  end

  def terminate(_, s) do
    if Port.info(s.port), do: Port.close(s.port)
    :ok
  end

  def trusted_path(path) do
    case EffectiveUID.resolve() do
      {:ok, uid} -> trusted_path(path, uid)
      _ -> {:error, :untrusted_artifact_root}
    end
  end

  defp trusted_path(path, uid) do
    components = Path.split(Path.expand(path))
    paths = Enum.scan(components, &Path.join(&2, &1))

    if Enum.all?(paths, &trusted_component?(&1, Path.expand(path), uid)),
      do: :ok,
      else: {:error, :untrusted_artifact_root}
  end

  defp root_identity(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, major_device: device, inode: inode}} -> {:ok, {device, inode}}
      _ -> {:error, :untrusted_artifact_root}
    end
  end

  defp trusted_component?(p, path, uid) do
    case File.lstat(p) do
      {:ok, %{type: :directory, uid: owner, mode: mode}} ->
        if p == path,
          do: owner == uid and (mode &&& 0o022) == 0,
          else: owner in [0, uid] and ((mode &&& 0o022) == 0 or (mode &&& 0o1000) != 0)

      _ ->
        false
    end
  end

  defp identity(root, uuid) do
    path = Path.join(root, "deployment-v2.json")
    bytes = MedEx.CanonicalJSON.encode(%{"revision" => "2", "deployment_uuid" => uuid})

    case File.read(path) do
      {:ok, ^bytes} ->
        :ok

      {:error, :enoent} ->
        initialize_identity(root, path, bytes)

      _ ->
        {:error, :artifact_identity_mismatch}
    end
  end

  defp synced({:ok, :ok}, root), do: sync_directory(root)
  defp synced(error, _), do: error

  def sync_directory(dir) do
    with {:ok, fd} <- :file.open(String.to_charlist(dir), [:raw, :read, :directory]) do
      try do
        :file.sync(fd)
      after
        :file.close(fd)
      end
    end
  end

  defp verified_quiescence?(proof, s, prefix, expected) do
    proof[:scope] == :full_journal and proof[:root_owner] == self() and
      proof[:root_token] == s.token and proof[:root] == s.root and
      proof[:receipt] == prefix.receipt and MedEx.Receipt.durable?(prefix.receipt) and
      String.starts_with?(Path.expand(prefix.artifact_dir), expected) and Port.info(s.port) != nil
  end

  defp initialize_identity(root, path, bytes) do
    case File.ls(root) do
      {:ok, []} ->
        File.open(path, [:write, :binary, :exclusive], &write_identity(&1, bytes))
        |> synced(root)

      _ ->
        {:error, :unmarked_artifact_namespace}
    end
  end

  defp write_identity(io, bytes) do
    :ok = IO.binwrite(io, bytes)
    :file.sync(io)
  end
end
