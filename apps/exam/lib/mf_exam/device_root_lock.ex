defmodule MedFabric.Exam.DeviceRootLock do
  @moduledoc "Exclusive service-owned root, immutable deployment identity and local effect gates. Lock loss is fail-stop."
  use GenServer
  import Bitwise
  def start_link(opts),do: GenServer.start_link(__MODULE__,opts,name: Keyword.fetch!(opts,:name))
  def gate(pid,key),do: GenServer.call(pid,{:gate,key},5_000)
  def release(pid,key),do: GenServer.call(pid,{:release,key},5_000)
  def recover_gate(pid,key),do: GenServer.call(pid,{:recover_gate,key},5_000)
  def settle_gate(pid,key,prefix),do: GenServer.call(pid,{:settle_gate,key,prefix},5_000)
  def poison(pid,key),do: GenServer.call(pid,{:poison,key},5_000)
  def bind_connection(pid,key,connection,socket),do: GenServer.call(pid,{:bind_connection,key,connection,socket},5_000)
  def current_connection?(pid,key,connection),do: GenServer.call(pid,{:current_connection,key,connection},5_000)
  def invalidate_connection(pid,key),do: GenServer.call(pid,{:invalidate_connection,key},5_000)

  def init(opts) do
    root=Path.expand(Keyword.fetch!(opts,:root))
    uuid=Keyword.fetch!(opts,:deployment_uuid)
    existed=File.exists?(root)
    with :ok <- File.mkdir_p(root),
         :ok <- if(existed,do: :ok,else: File.chmod(root,0o700)),
         :ok <- trusted_path(root), :ok <- identity(root,uuid),
         executable when is_binary(executable) <- System.find_executable("flock") do
      path=Path.join(root,"capture-service.lock")
      port=Port.open({:spawn_executable,String.to_charlist(executable)},[:binary,:exit_status,:use_stdio,
        {:args,Enum.map(["--nonblock","--no-fork",path,"sh","-c","echo locked && exec cat >/dev/null"],&String.to_charlist/1)}])
      receive do
        {^port,{:data,"locked\n"}} -> {:ok,%{root: root,uuid: uuid,port: port,token: make_ref(),gates: %{},connections: %{}}}
        {^port,{:exit_status,_}} -> {:stop,:artifact_root_in_use}
      after
        5_000 -> if Port.info(port),do: Port.close(port); {:stop,:artifact_lock_timeout}
      end
    else
      {:error,reason} -> {:stop,reason}
      _ -> {:stop,:root_lock_unavailable}
    end
  end

  def handle_call({:med_ex_root_ownership,path},_,s) do
    inside=Path.expand(path) == s.root or String.starts_with?(Path.expand(path),s.root<>"/")
    if inside and Port.info(s.port) != nil and trusted_path(s.root) == :ok,
      do: {:reply,{:ok,%{root: s.root,token: s.token}},s},else: {:reply,{:error,:root_ownership_lost},s}
  end
  def handle_call({:bind_connection,key,connection,socket},{pid,_},s) do
    case s.gates[key] do
      %{owner: ^pid,poisoned: false} ->
        if s.connections[key],do: Process.demonitor(s.connections[key].ref,[:flush])
        {:reply,:ok,put_in(s.connections[key],%{connection: connection,socket: socket,ref: Process.monitor(socket)})}
      _ -> {:reply,{:error,:gate_owner_required},s}
    end
  end
  def handle_call({:current_connection,key,connection},_,s) do
    active=case s.connections[key] do %{connection: ^connection,socket: socket}->Process.alive?(socket); _->false end
    {:reply,active,s}
  end
  def handle_call({:invalidate_connection,key},{socket,_},s) do
    case s.connections[key] do
      %{socket: ^socket,ref: ref}->Process.demonitor(ref,[:flush]); {:reply,:ok,%{s|connections: Map.delete(s.connections,key)}}
      _->{:reply,:ok,s}
    end
  end
  def handle_call({:gate,key},{pid,_},s) do
    case s.gates[key] do
      nil -> ref=Process.monitor(pid); {:reply,:ok,put_in(s.gates[key],%{owner: pid,ref: ref,poisoned: false})}
      %{owner: ^pid,poisoned: false} -> {:reply,:ok,s}
      %{poisoned: true} -> {:reply,{:error,:prior_effect_quiescence_required},s}
      _ -> {:reply,{:error,:effect_in_flight},s}
    end
  end
  def handle_call({:recover_gate,key},{pid,_},s) do
    case s.gates[key] do
      %{owner: owner,ref: ref,poisoned: true} ->
        if owner == pid or not Process.alive?(owner) do
          Process.demonitor(ref,[:flush])
          {:reply,:ok,put_in(s.gates[key],%{owner: pid,ref: Process.monitor(pid),poisoned: true})}
        else {:reply,{:error,:prior_owner_alive},s} end
      _ -> {:reply,{:error,:recovery_not_required},s}
    end
  end
  def handle_call({:settle_gate,{id,name}=key,%MedEx.Storage.RecoveredPrefix{}=prefix},{pid,_},s) do
    expected=Path.join([s.root,"acquisitions-v2",MedFabric.Store.AcquisitionSessions.hash(id),name])<>"/"
    proof=prefix.provenance
    case s.gates[key] do
      %{owner: ^pid,poisoned: true}=gate ->
        if proof[:scope] == :full_journal and proof[:root_owner] == self() and proof[:root_token] == s.token and
          proof[:root] == s.root and proof[:receipt] == prefix.receipt and MedEx.Receipt.durable?(prefix.receipt) and
          String.starts_with?(Path.expand(prefix.artifact_dir),expected) and Port.info(s.port) != nil do
          {:reply,:ok,put_in(s.gates[key],%{gate|poisoned: false})}
        else {:reply,{:error,:unverified_quiescence},s} end
      _ -> {:reply,{:error,:gate_owner_required},s}
    end
  end
  def handle_call({:settle_gate,_,_},_,s),do: {:reply,{:error,:unverified_quiescence},s}
  def handle_call({:poison,key},{pid,_},s) do
    case s.gates[key] do
      %{owner: ^pid}=gate -> {:reply,:ok,put_in(s.gates[key],%{gate|poisoned: true})}
      _ -> {:reply,{:error,:gate_owner_required},s}
    end
  end
  def handle_call({:release,key},{pid,_},s) do
    case s.gates[key] do
      %{owner: ^pid,ref: ref,poisoned: false} -> Process.demonitor(ref,[:flush]); {:reply,:ok,%{s|gates: Map.delete(s.gates,key)}}
      _ -> {:reply,{:error,:gate_owner_required},s}
    end
  end
  def handle_info({:DOWN,ref,:process,_,_},s),do: {:noreply,%{s|
    connections: Map.reject(s.connections,fn {_,connection}->connection.ref == ref end),
    gates: Map.new(s.gates,fn {k,v}->{k,if(v.ref == ref,do: %{v|poisoned: true},else: v)} end)}}
  def handle_info({port,{:exit_status,_}},%{port: port}=s) do
    System.halt(1)
    {:stop,:root_ownership_lost,s}
  end
  def handle_info(_,s),do: {:noreply,s}
  def terminate(_,s) do
    if Port.info(s.port),do: Port.close(s.port)
    :ok
  end

  def trusted_path(path) do
    {:ok,%{uid: uid}}=File.stat("/proc/self")
    components=Path.split(Path.expand(path))
    paths=Enum.scan(components,&Path.join(&2,&1))
    if Enum.all?(paths,fn p -> case File.lstat(p) do
      {:ok,%{type: :directory,uid: owner,mode: mode}} ->
        if p == Path.expand(path),do: owner == uid and (mode &&& 0o022) == 0,
          else: owner in [0,uid] and ((mode &&& 0o022) == 0 or (mode &&& 0o1000) != 0)
      _ -> false
    end end),do: :ok,else: {:error,:untrusted_artifact_root}
  end
  defp identity(root,uuid) do
    path=Path.join(root,"deployment-v2.json")
    bytes=MedEx.CanonicalJSON.encode(%{"revision"=>2,"deployment_uuid"=>uuid})
    case File.read(path) do
      {:ok,^bytes} -> :ok
      {:error,:enoent} ->
        case File.ls(root) do
          {:ok,[]} -> File.open(path,[:write,:binary,:exclusive],fn io -> :ok=IO.binwrite(io,bytes); :file.sync(io) end) |> synced(root)
          _ -> {:error,:unmarked_artifact_namespace}
        end
      _ -> {:error,:artifact_identity_mismatch}
    end
  end
  defp synced({:ok,:ok},root),do: sync_directory(root)
  defp synced(error,_),do: error
  def sync_directory(dir) do
    with {:ok,fd} <- :file.open(String.to_charlist(dir),[:raw,:read,:directory]) do
      try do :file.sync(fd) after :file.close(fd) end
    end
  end
end
