defmodule MedFabric.ExamWeb.DeviceSocket do
  @moduledoc "Authenticated independent WSS connections for control, authoritative streams and disposable monitor."
  @behaviour WebSock
  import Plug.Conn
  alias MedFabric.Store.{DeviceSessions,DeviceCommands,MeasurementEvents}
  alias DeviceSessions, as: S
  alias MedFabric.Exam.{DeviceIngress,DeviceManifest,ClockObservations,Barrier}
  alias MedEx.Serialization, as: J

  def init(opts) when is_atom(opts),do: opts
  def init(%{}=state),do: {:ok,state}

  def call(conn,kind) do
    with true <- MedFabric.Exam.lab()[:device_enabled]==true and conn.scheme==:https,
         ["Bearer "<>credential] <- get_req_header(conn,"authorization"),
         {:ok,device} <- S.authenticate(credential) do
      WebSockAdapter.upgrade(conn,__MODULE__,%{kind: kind,device: device,bind: nil,writer: nil,probe: nil,pending: false},max_frame_size: 65_584,timeout: 65_000)
    else _ -> send_resp(conn,403,"Device TLS and enrollment required") end
  end

  def handle_in({bytes,[opcode: :text]},state) when byte_size(bytes)<=16_384 do
    try do
      ops= ~w(hello open_stream open_monitor heartbeat result measurement probe probe_reply anchor status collection_finish finish_acquisition gap finish)
      case MedEx.Wire.Control.decode(bytes,ops) do
        {:ok,%{"type"=>type}=msg} -> handle(type,msg,state)
        _ -> denied(state)
      end
    rescue
      _ in [ArgumentError,KeyError,FunctionClauseError,MatchError] -> denied(state)
    catch
      :invalid -> denied(state)
    end
  end
  def handle_in({raw,[opcode: :binary]},%{kind: :stream,writer: pid,pending: false}=s) when is_pid(pid) do
    case DeviceIngress.call(pid,{:frame,raw}) do
      {:ok,r} -> send(self(),:checkpoint); reply("accepted",Map.put(J.to_map(r),"transport_sha256",S.hash(raw)),%{s | pending: true})
      {:error,{:replay,q,n}} -> reply("replay",%{"sequence"=>to_string(q),"sample"=>to_string(n)},s)
      _ -> denied(s)
    end
  end
  def handle_in({raw,[opcode: :binary]},%{kind: :monitor,bind: b}=s) when is_map(b) do
    with {:ok,f} <- MedEx.Wire.FrameV1.decode(raw),true <- f.stream_number==3,
         {:ok,:ok} <- S.scoped(b,fn tx,session ->
           unless session.phase=="capturing" and session.profile=="paired_exam" and
             session.descriptors["audio"]["encoding"]=="s16le" and session.descriptors["audio"]["sample_rate"]==["48000","1"] and length(session.descriptors["audio"]["channels"])==1 and f.sample_count==960 and byte_size(f.payload)==1920 and
             to_string(f.source_epoch)==session.descriptors["audio"]["source_epoch"], do: S.abort(tx,:invalid_monitor)
           MedFabric.Exam.PreviewGateway.feed(b.id,raw)
         end) do
      reply("monitor_credit",%{},s)
    else _ -> denied(s) end
  end
  def handle_in(_,s),do: denied(s)

  defp handle("hello",%{"acquisition"=>id,"encounter"=>enc,"profile"=>p,"boot"=>boot,"descriptors"=>descs},%{kind: :control,bind: nil}=s) do
    with true <- Enum.all?([id,enc,boot],&identifier?/1), true <- valid_descriptors?(p,descs,id,s.device),
         {:ok,b} <- S.reserve(s.device,enc,id,p,boot,descs) do
      reply("admitted",%{"lease"=>b.lease,"generation"=>to_string(b.generation),"acquisition"=>id,"phase"=>b.phase,
        "stream_numbers"=>%{"audio"=>1,"ecg"=>2,"monitor"=>3},"credit_frames"=>1},%{s | bind: b})
    else _ -> denied(s) end
  end
  defp handle("open_stream",%{"acquisition"=>id,"generation"=>g,"lease"=>lease,"stream"=>n,"descriptor_ref"=>digest},%{kind: :stream,bind: nil}=s) do
    b=%{id: id,device: s.device,generation: String.to_integer(g),lease: lease}
    case DeviceIngress.open(b,n,digest) do
      {:ok,p,r} -> reply("durable",J.to_map(r),Map.merge(s,%{bind: b,writer: p,stream: n}))
      {:error,{:sealed,r}} -> reply("stream_finished",r,%{s | bind: b})
      _ -> denied(s)
    end
  end
  defp handle("open_monitor",%{"acquisition"=>id,"generation"=>g,"lease"=>lease},%{kind: :monitor,bind: nil}=s) do
    b=%{id: id,device: s.device,generation: String.to_integer(g),lease: lease}
    case S.scoped(b,fn _,session->session.profile=="paired_exam" and session.phase=="capturing" end) do
      {:ok,true}->reply("monitor_credit",%{"source_stream"=>"audio","transform"=>"monitor_gain_v1","domain"=>"handheld_monitor"},%{s | bind: b})
      _->denied(s)
    end
  end
  defp handle("gap",m,%{kind: :stream,writer: pid,pending: false}=s) when is_pid(pid) do
    case DeviceIngress.call(pid,{:gap,m}) do
      {:ok,_}->send(self(),:checkpoint);reply("accepted",%{},%{s | pending: true})
      _->denied(s)
    end
  end
  defp handle("finish",%{"sequence"=>q,"sample"=>n}=m,%{kind: :stream,writer: p,pending: false}=s) when is_pid(p) do
    case DeviceIngress.call(p,{:finish,q,n,m["interruption"]}) do
      {:ok,r}-> reply("stream_finished",J.to_map(r),%{s | writer: nil})
      _->denied(s)
    end
  end
  defp handle("heartbeat",_,%{kind: :control,bind: b}=s) when is_map(b) do
    with {:ok,:ok} <- S.heartbeat(b),{:ok,msg} <- DeviceCommands.poll(b) do
      action = S.rows(MedFabric.Store.Postgres,"SELECT fact FROM device_facts WHERE acquisition_id=$1 AND kind='operator_stop' LIMIT 1",[b.id])  !=  []
      reply(msg["type"],Map.put(msg,"stop_requested",action),s)
    else _->denied(s) end
  end
  defp handle("result",m,%{kind: :control,bind: b}=s) when is_map(b) do
    case DeviceCommands.result(b,Map.drop(m,["schema","type"])) do {:ok,:ok}->reply("result_saved",%{},s); _->denied(s) end
  end
  defp handle("measurement",%{"event"=>e},%{kind: :control,bind: b}=s) when is_map(b) do
    with :ok <- MedFabric.Domain.DeviceMeasurement.validate(e),
         hash=J.digest(e),{:ok,r}<-MeasurementEvents.put(b,e,hash) do
      Barrier.hit("measurement_commit")
      reply(to_string(r),%{"event_id"=>e["event_id"],"fingerprint"=>hash,"generation"=>to_string(b.generation)},s)
    else _->denied(s) end
  end
  defp handle("probe",%{"stream"=>n},%{kind: :control,bind: b}=s) when is_map(b) and n in ["audio","ecg"] do
    with {:ok,true} <- S.scoped(b,fn _,v->v.phase=="capturing" end) do
      id=S.nonce(); h1=ClockObservations.now()
      reply("probe",%{"id"=>id,"stream"=>n},%{s | probe: {id,n,h1}})
    else _->denied(s) end
  end
  defp handle("probe_reply",%{"id"=>id,"d2"=>d2,"d3"=>d3},%{kind: :control,probe: {id,n,h1}}=s) do
    h4=ClockObservations.now()
    if number?(d2) and number?(d3) and String.to_integer(d2)<=String.to_integer(d3) do
      fact(s,"probe",%{"stream"=>n,"h1"=>to_string(h1),"h4"=>to_string(h4),"d2"=>d2,"d3"=>d3,"host_generation"=>ClockObservations.host_generation()})
    else denied(s) end
  end
  defp handle("anchor",%{"stream"=>n,"method"=>"fixture_acquisition_tick","sample_index"=>i,"tick"=>t,"error_us"=>err}=m,%{kind: :control,bind: b}=s) when is_map(b) and n in ["audio","ecg"] do
    if Enum.all?([i,t,err],&number?/1),do: fact(s,"anchor",Map.take(m,~w(stream method sample_index tick error_us))),else: denied(s)
  end
  defp handle("status",%{"state"=>v}=m,%{kind: :control,bind: b}=s) when is_map(b) and v in ["acquiring","provisional","repeat","unusable_completed","replaying","interrupted"], do: fact(s,"status",Map.take(m,~w(state event_id repeat_of reason)))
  defp handle(t,m,%{kind: :control,bind: b}=s) when t in ["collection_finish","finish_acquisition"] and is_map(b) do
    case DeviceManifest.finish(b,Map.take(m,["count","digest"])) do
      {:ok,digest}->MedFabric.Exam.announce(b.encounter);reply("sealed",%{"digest"=>digest},s)
      {:error,:inventory_pending}->reply("inventory_pending",%{},s)
      _->denied(s)
    end
  end
  defp handle(_,_,s),do: denied(s)
  defp fact(s,type,body) do
    case S.scoped(s.bind,fn tx,v->
      if v.phase != "capturing",do: S.abort(tx,:inactive)
      if S.rows(tx,"SELECT count(*) FROM device_facts WHERE acquisition_id=$1",[s.bind.id])==[[100_000]],do: S.abort(tx,:capacity)
      S.fact(tx,s.bind.id,type,body)
    end) do
      {:ok,_}->reply("recorded",%{},%{s | probe: nil})
      _->denied(s)
    end
  end
  def handle_info(:checkpoint,s) do
    Barrier.hit("accepted_before_durable",s.stream)
    case DeviceIngress.call(s.writer,:checkpoint) do
      {:ok,r}->Barrier.hit("durable_before_ack",s.stream);reply("durable",J.to_map(r),%{s | pending: false})
      _->denied(s)
    end
  end
  def handle_info(_,s),do: {:ok,s}
  def terminate(_,%{kind: :control,bind: b}) when is_map(b),do: S.disconnected(b)
  def terminate(_, _),do: :ok
  defp reply(t,data,s),do: {:push,{:text,Jason.encode!(Map.merge(data,%{"schema"=>"medex.device.v1","type"=>t}))},s}
  defp denied(s),do: {:stop,:normal,1008,{:text,"device_request_denied"},s}
  defp number?(s),do: is_binary(s) and Regex.match?(~r/\A(0|[1-9][0-9]{0,18})\z/,s)
  defp identifier?(s),do: is_binary(s) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,96}\z/,s)
  defp valid_descriptors?("plx_spot_check",d,_,_),do: d==%{}
  defp valid_descriptors?("paired_exam",d,id,device) when is_map(d) and map_size(d)==2 do
    Enum.all?(~w(audio ecg),fn n->
      with {:ok,s}<-J.stream_spec(d[n]) do
        s.stream_id==n and s.acquisition_id==id and s.source_ref==device and s.source_epoch==0 and
          s.modality==(if n=="audio",do: "medex:diagnostic_audio",else: "medex:ecg") and
          s.descriptor_ref==J.descriptor_ref(s) and J.to_map(s)==d[n]
      else _->false end
    end)
  end
  defp valid_descriptors?(_,_,_,_),do: false
end
