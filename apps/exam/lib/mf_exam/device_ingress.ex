defmodule MedFabric.Exam.DeviceIngress do
  unless Code.ensure_loaded?(MedEx.StreamWriter),do: raise("Select the MedEx stream-v1 source checkout in .mix_sources.json; the legacy Hex SDK lacks StreamWriter")
  @moduledoc "One independently scheduled writer and one active socket per immutable source stream."
  use GenServer, restart: :temporary
  alias MedEx.{StreamWriter,Serialization,SampleFrame,IntegritySpan}
  alias MedEx.Wire.FrameV1
  alias MedFabric.Store.DeviceSessions, as: S
  alias MedFabric.Exam.{DeviceManifest,Barrier}

  def start_link(key), do: GenServer.start_link(__MODULE__,nil,name: {:via,Registry,{MedFabric.Exam.DeviceRegistry,key}})
  def init(nil),do: {:ok,nil}
  def open(bind,name,digest) when name in ["audio","ecg"] do
    with {:ok,true} <- S.scoped(bind,fn _,session -> get_in(session.descriptors,[name,"descriptor_ref"])==digest end) do
      open_verified(bind,name,digest)
    else _->{:error,:binding_denied} end
  end
  defp open_verified(bind,name,digest) do
    key={bind.id,name}
    pid=case DynamicSupervisor.start_child(MedFabric.Exam.Captures,{__MODULE__,key}) do
      {:ok,p} -> p
      {:error,{:already_started,p}} -> p
    end
    case GenServer.call(pid,{:open,bind,name,digest},35_000) do
      {:ok,r} -> {:ok,pid,r}
      e -> e
    end
  end
  def call(pid,op),do: GenServer.call(pid,op,35_000)

  def handle_call({:open,b,n,digest},{socket,_},old) do
    cond do
      old && old.bind.generation>b.generation -> {:reply,{:error,:old_generation},old}
      old && old.bind.generation==b.generation && old.socket  !=  socket && Process.alive?(old.socket) -> {:reply,{:error,:already_open},old}
      old && old.bind.generation==b.generation && old.digest==digest ->
        {:reply,StreamWriter.receipt(old.writer),%{old | socket: socket}}
      true ->
        case S.scoped(b,fn tx,s ->
          unless s.profile=="paired_exam" and s.phase in ["capturing","finalizing","sealed"],do: S.abort(tx,:inactive)
          {:ok,spec}=Serialization.stream_spec(s.descriptors[n])
          if spec.descriptor_ref != digest,do: S.abort(tx,:descriptor_changed)
          # A new writer is never opened while its predecessor is running.
          if old && Process.alive?(old.writer) do
            case StreamWriter.interrupt(old.writer,"transport_generation_rotated") do
              {:ok,_}-> await_dead(old.writer)
              _ -> S.abort(tx,:cannot_quiesce)
            end
          end
          number=if n=="audio",do: 1,else: 2
          prev=S.rows(tx,"SELECT fence,receipt,sealed_index FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 ORDER BY generation DESC LIMIT 1 FOR UPDATE",[b.id,n])
          case prior(tx,prev,b.id,n,spec) do
            {:sealed,r} -> {:sealed,r}
            previous ->
              fence=S.nonce()
              # Commit the reservation BEFORE opening a new writable directory.
              S.rows(tx,"INSERT INTO stream_attempts(acquisition_id,stream,number,generation,fence) VALUES($1,$2,$3,$4,$5)",[b.id,n,number,b.generation,fence])
              {:reserved,fence,spec,number,previous}
          end
        end,:update) do
          {:ok,{:sealed,r}} -> {:stop,:normal,{:error,{:sealed,r}},old}
          {:ok,{:reserved,fence,spec,number,previous}} ->
            opts=[owner: self(),stream: spec,fence: fence,artifact_dir: DeviceManifest.attempt_dir(b.id,n,fence),
              fault_hook: fn stage->Barrier.hit(to_string(stage),n) end]
            with {:ok,w} <- StreamWriter.start_link(opts++previous),
                 {:ok,r} <- StreamWriter.receipt(w),
                 {:ok,_} <- S.scoped(b,fn tx,_->
                   S.rows(tx,"UPDATE stream_attempts SET receipt=$2 WHERE fence=$1",[fence,Serialization.to_map(r)])
                 end) do
              new=%{writer: w,bind: b,name: n,socket: socket,spec: spec,number: number,digest: digest,fence: fence,receipt: r}
              {:reply,{:ok,r},new}
            else error -> {:stop,:normal,error,old} end
          error -> {:reply,error,old}
        end
    end
  end

  def handle_call(:expire,_,%{writer: writer}=s) do
    result=StreamWriter.interrupt(writer,"resume_deadline")
    if match?({:ok,_},result),do: await_dead(writer)
    {:stop,:normal,result,s}
  end
  def handle_call(op,{socket,_},%{socket: socket}=s) do
    result=S.scoped(s.bind,fn tx,session ->
      unless session.phase in ["capturing","finalizing"],do: S.abort(tx,:inactive)
      case op do
        {:frame,raw} ->
          Barrier.hit("writer_stall",s.name)
          payload=max(0,byte_size(raw)-48)
          S.rows(tx,"INSERT INTO device_limits_observed(fence,max_frame_bytes,max_pending_bytes,max_pending_frames) VALUES($1,$2,$2,1) ON CONFLICT(fence) DO UPDATE SET max_frame_bytes=greatest(device_limits_observed.max_frame_bytes,$2),max_pending_bytes=greatest(device_limits_observed.max_pending_bytes,$2)",[s.fence,payload])
        _->:ok
      end
      case act(op,s) do
        {:ok,%MedEx.StreamIndex{}=index} ->
          await_dead(s.writer)
          dir=DeviceManifest.attempt_dir(s.bind.id,s.name,s.fence)
          {:ok,%{sealed: true,index: ^index,receipt: r}}=MedEx.Storage.File.recover(dir,stream: s.spec,fence: s.fence)
          S.rows(tx,"UPDATE stream_attempts SET sealed_index=$2,index_digest=$3,receipt=$4 WHERE fence=$1",[s.fence,Serialization.to_map(index),Serialization.digest(index),Serialization.to_map(r)])
          {:sealed,r}
        {:ok,r} when op==:checkpoint ->
          Barrier.hit("journal_sync",s.name)
          S.rows(tx,"UPDATE device_limits_observed SET durable_acks=durable_acks+1 WHERE fence=$1",[s.fence])
          S.rows(tx,"UPDATE stream_attempts SET receipt=$2 WHERE fence=$1",[s.fence,Serialization.to_map(r)])
          {:receipt,r}
        {:ok,r} ->
          case op do
            {:frame,bytes} ->
              {:ok,frame}=FrameV1.decode(bytes)
              if s.name=="ecg" and :ets.whereis(:mf_live_ecg) != :undefined,do: :ets.insert(:mf_live_ecg,{s.bind.id,System.monotonic_time(:millisecond),s.spec,frame})
              S.rows(tx,"INSERT INTO device_transport_observations(fence,sequence,raw_digest) VALUES($1,$2,$3) ON CONFLICT DO NOTHING",[s.fence,frame.sequence,S.hash(bytes)])
            _->:ok
          end
          usage=StreamWriter.stats(s.writer)
          S.rows(tx,"UPDATE device_limits_observed SET max_pending_bytes=greatest(max_pending_bytes,$2),max_pending_frames=greatest(max_pending_frames,$3) WHERE fence=$1",[s.fence,usage.peak_pending_bytes,usage.peak_pending_frames])
          {:receipt,r}
        {:error,:duplicate_conflict} ->
          await_dead(s.writer)
          dir=DeviceManifest.attempt_dir(s.bind.id,s.name,s.fence)
          {:ok,%{sealed: true,index: ix,receipt: r}}=MedEx.Storage.File.recover(dir,stream: s.spec,fence: s.fence)
          S.rows(tx,"UPDATE stream_attempts SET sealed_index=$2,index_digest=$3,receipt=$4 WHERE fence=$1",[s.fence,Serialization.to_map(ix),Serialization.digest(ix),Serialization.to_map(r)])
          S.fact(tx,s.bind.id,"duplicate_conflict",%{"stream"=>s.name})
          {:error,:duplicate_conflict}
        error -> error
      end
    end)
    case result do
      {:ok,{:sealed,r}} -> {:stop,:normal,{:ok,r},s}
      {:ok,{:receipt,r}} -> {:reply,{:ok,r},%{s | receipt: r}}
      {:ok,{:error,:duplicate_conflict}=error} -> {:stop,:normal,error,s}
      {:ok,error} -> {:reply,error,s}
      error -> {:reply,error,s}
    end
  end
  def handle_call(_,_,s),do: {:reply,{:error,:stale_socket},s}

  defp act({:frame,raw},s) do
    with {:ok,f} <- FrameV1.decode(raw), true <- f.stream_number==s.number and f.source_epoch==s.spec.source_epoch do
      frame=struct!(SampleFrame,Map.merge(Map.take(Map.from_struct(f),[:source_epoch,:sequence,:first_sample,:sample_count,:config_epoch,:payload]),%{descriptor_ref: s.digest,stream_id: s.name}))
      StreamWriter.push(s.writer,frame)
    else _ -> {:error,:wrong_frame} end
  end
  defp act({:gap,%{"id"=>id,"first"=>a,"end"=>b,"first_sequence"=>q,"next_sequence"=>r,"irreversible"=>true,"cause"=>cause}},s) when is_binary(cause) and byte_size(cause)<=256 do
    span=%IntegritySpan{stream_id: s.name,source_epoch: s.spec.source_epoch,code: :source_gap,source: "handheld",first_sample: uint(a),end_sample: uint(b),context: %{"cause"=>cause}}
    StreamWriter.record_gap(s.writer,%{id: id,span: span,first_sequence: uint(q),next_sequence: uint(r),irreversible: true})
  end
  defp act(:checkpoint,s),do: StreamWriter.checkpoint(s.writer)
  defp act({:finish,seq,count,interruption},s) do
    with {:ok,r} <- StreamWriter.checkpoint(s.writer), true <- {uint(seq),uint(count)}=={r.durable_sequence,r.durable_sample} do
      if interruption in ["spool_full","source_reset"],do: StreamWriter.interrupt(s.writer,interruption),else: StreamWriter.finish(s.writer)
    else _ -> {:error,:finish_mismatch} end
  end
  defp act(_, _),do: {:error,:unsupported}
  defp uint(s) when is_binary(s) and byte_size(s) in 1..20 do
    case Integer.parse(s) do {n,""} when n>=0 -> n; _ -> :invalid end
  end
  defp uint(_),do: :invalid
  defp await_dead(pid) do
    ref=Process.monitor(pid)
    receive do {:DOWN,^ref,:process,^pid,_}->:ok after 30_000->raise "prior writer not quiescent" end
  end

  def handle_info({:med_ex_durable,pid,r},%{writer: pid}=s) do
    if r.fence==s.fence do
      S.scoped(s.bind,fn tx,_->
        S.rows(tx,"UPDATE stream_attempts SET receipt=$2 WHERE fence=$1 AND coalesce((receipt->>'journal_generation')::bigint,0)<$3",[s.fence,Serialization.to_map(r),r.journal_generation])
      end)
    end
    {:noreply,s}
  end
  def handle_info({:med_ex_storage_failed,pid,_},%{writer: pid}=s),do: {:stop,:normal,s}
  def handle_info(_,s),do: {:noreply,s}

  defp prior(_,[],_,_,_),do: []
  defp prior(_,[[_,receipt,index]],_,_,_) when not is_nil(index),do: {:sealed,receipt}
  defp prior(tx,[[fence,known,nil]],id,name,spec) do
    dir=DeviceManifest.attempt_dir(id,name,fence)
    if is_nil(known) and not File.exists?(dir) do
      # Crash after reserving a successor but before opening it. Walk past this
      # empty reservation. Its predecessor may already contain durable samples.
      prev=S.rows(tx,"SELECT fence,receipt,sealed_index FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 AND generation<(SELECT generation FROM stream_attempts WHERE fence=$3) ORDER BY generation DESC LIMIT 1",[id,name,fence])
      prior(tx,prev,id,name,spec)
    else
      opts=[stream: spec,fence: fence] ++ if(known,do: [known_receipt: elem(Serialization.receipt(known),1)],else: [])
      recovery=case MedEx.Storage.File.recover(dir,opts) do
        {:ok,%{terminal_recorded: true,sealed: false}} -> MedEx.Storage.File.reconcile_index(dir,opts)
        result -> result
      end
      case recovery do
        {:ok,%{sealed: true,index: %{terminal: terminal}=i,receipt: r}} when terminal in [:finished,:failed] ->
          S.rows(tx,"UPDATE stream_attempts SET sealed_index=$2,index_digest=$3,receipt=$4 WHERE fence=$1",[fence,Serialization.to_map(i),Serialization.digest(i),Serialization.to_map(r)])
          {:sealed,Serialization.to_map(r)}
        {:ok,%{receipt: r}} -> [predecessor: %{artifact_dir: dir,receipt: r}]
        _ -> S.abort(tx,:unverified_predecessor)
      end
    end
  end
end
