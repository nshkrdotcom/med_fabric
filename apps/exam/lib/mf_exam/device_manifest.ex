defmodule MedFabric.Exam.DeviceManifest do
  @moduledoc "Verify native bytes before immutable manifest install and database completion."
  alias MedFabric.Store.{DeviceSessions,MeasurementEvents,Postgres}
  alias DeviceSessions, as: S
  alias MedFabric.Exam.{Barrier,ClockObservations}
  alias MedEx.Serialization, as: J

  def root(id),do: Path.join([MedFabric.Exam.lab().artifact_dir,"device-v1",S.hash(id)])
  def attempt_dir(id,stream,fence),do: Path.join([root(id),stream,fence])
  def inventory_digest(entries),do: J.digest(for row<-entries,do: [row["event"]["event_id"],row["fingerprint"]])

  def finish(bind,final) do
    with {:ok,:ok} <- S.scoped(bind,fn tx,s ->
      if (s.profile=="plx_spot_check" and not valid_inventory?(final)) or (s.profile=="paired_exam" and final != %{}),do: S.abort(tx,:invalid_finish)
      case S.rows(tx,"SELECT final_inventory FROM device_sessions WHERE id=$1",[bind.id]) do
        [[nil]] -> S.rows(tx,"UPDATE device_sessions SET phase='finalizing',final_inventory=$2 WHERE id=$1",[bind.id,final])
        [[^final]] -> :ok
        _ -> S.abort(tx,:finish_conflict)
      end
      :ok
    end,:update) do
      with {:ok,_} <- S.scoped(bind,fn tx,s -> stage(tx,bind.id,s,final) end,:update) do
        S.scoped(bind,fn tx,s -> finalize(tx,bind.id,s) end,:update)
      end
    end
  end

  defp valid_inventory?(%{"count"=>n,"digest"=>d}) when is_binary(n) and is_binary(d),
    do: Regex.match?(~r/\A(0|[1-9][0-9]{0,4})\z/,n) and String.to_integer(n)<=10_000 and Regex.match?(~r/\A[0-9a-f]{64}\z/,d)
  defp valid_inventory?(_),do: false

  defp stage(tx,id,s,final) do
    case S.rows(tx,"SELECT digest FROM device_manifest_staging WHERE acquisition_id=$1",[id]) do
      [[digest]] -> digest
      [] ->
        inventory=MeasurementEvents.inventory(tx,id)
        if s.profile=="plx_spot_check" and (to_string(length(inventory)) != final["count"] or inventory_digest(inventory) != final["digest"] or
          not Enum.all?(Enum.with_index(inventory),fn {r,n}->r["event"]["gateway_sequence"]==to_string(n) end)), do: S.abort(tx,:inventory_pending)
        :ok=MedFabric.Store.DeviceCommands.close_pending(tx,id)
        facts=S.facts(tx,id)
        streams=Map.new(s.descriptors,fn {name,descriptor} ->
          {:ok,spec}=J.stream_spec(descriptor)
          case S.rows(tx,"SELECT fence,index_digest,receipt FROM stream_attempts WHERE acquisition_id=$1 AND stream=$2 ORDER BY generation DESC LIMIT 1",[id,name]) do
            [[fence,digest,known]] ->
              with {:ok,k} <- J.receipt(known),
                   {:ok,%{sealed: true,index: index,receipt: r}} <- MedEx.Storage.File.recover(attempt_dir(id,name,fence),stream: spec,fence: fence,known_receipt: k),
                   actual=J.digest(index),true <- is_nil(digest) or digest==actual do
                S.rows(tx,"UPDATE stream_attempts SET index_digest=$2,sealed_index=$3,receipt=$4 WHERE fence=$1",[fence,actual,J.to_map(index),J.to_map(r)])
                {name,%{"digest"=>actual,"index"=>J.to_map(index),"clock"=>ClockObservations.freeze(name,spec,facts)}}
              else _ -> S.abort(tx,:unverified_stream) end
            [] -> S.abort(tx,:missing_stream)
          end
        end)
        defects=for {name,stream}<-Enum.sort(streams),code<-defects(stream),do: %{"stream"=>name,"code"=>code}
        defects=defects ++ (for f<-facts,f["type"] in ["duplicate_conflict","quarantine"],do: %{"stream"=>f["body"]["stream"],"code"=>f["type"]})
        reason=if s.profile=="plx_spot_check" and inventory==[],do: [%{"code"=>"empty_inventory"}],else: []
        [[gateway,repeat_of]]=S.rows(tx,"SELECT device_id,repeat_of FROM device_sessions WHERE id=$1",[id])
        receipts=for [name,fence,seq,digest,at]<-S.rows(tx,"SELECT a.stream,a.fence,o.sequence,o.raw_digest,o.received_at FROM device_transport_observations o JOIN stream_attempts a USING(fence) WHERE a.acquisition_id=$1 ORDER BY a.stream,a.generation,o.sequence,o.raw_digest",[id]),
          do: [name,fence,to_string(seq),digest,DateTime.to_iso8601(at)]
        summary=%{"sha256"=>J.digest(receipts),"count"=>to_string(length(receipts)),"basis"=>"server_transport_observation"}
        manifest=%{"gateway"=>gateway,"repeat_of"=>repeat_of,"transport_inventory"=>summary,"schema"=>"medfabric.device-manifest.v1","simulated"=>true,"acquisition"=>id,"encounter"=>s.encounter,
          "profile"=>s.profile,"site"=>s.site,"boot"=>s.boot,"streams"=>streams,"facts"=>facts,"inventory"=>inventory,"defects"=>defects++reason}
        bytes=MedEx.CanonicalJSON.encode(manifest)
        digest=S.hash(bytes)
        S.rows(tx,"INSERT INTO device_manifest_staging(acquisition_id,digest,bytes) VALUES($1,$2,$3)",[id,digest,bytes])
        digest
    end
  end

  defp finalize(tx,id,s) do
    [[digest,body]]=S.rows(tx,"SELECT digest,bytes FROM device_manifest_staging WHERE acquisition_id=$1",[id])
    unless S.hash(body)==digest,do: S.abort(tx,:manifest_conflict)
    file=Path.join(root(id),"manifest.mej1")
    case File.read(file) do
      {:ok,^body} -> :ok
      {:error,:enoent} -> install!(file,body)
      _ -> S.abort(tx,:manifest_conflict)
    end
    case S.rows(tx,"SELECT digest FROM device_manifests WHERE acquisition_id=$1",[id]) do
      [[^digest]] -> digest
      [] ->
        m=JSON.decode!(body)
        # Each retry revalidates the selected immutable journal and native objects.
        for {name,v}<-m["streams"] do
          ix=v["index"]; {:ok,spec}=J.stream_spec(ix["stream"])
          case MedEx.Storage.File.recover(attempt_dir(id,name,ix["fence"]),stream: spec,fence: ix["fence"]) do
            {:ok,%{sealed: true,index_digest: actual}} when actual==:erlang.map_get("digest",v)->:ok
            _->S.abort(tx,:unverified_stream)
          end
        end
        Barrier.hit("manifest_install")
        state=if m["defects"]==[],do: "ready",else: "ready_partial"
        evidence=%{"kind"=>s.profile,"manifest_digest"=>digest,"provenance"=>%{"kind"=>"simulated_device","simulated"=>true}}
        if S.rows(tx,"UPDATE acquisitions SET state=$3,evidence=$4,producer=NULL WHERE encounter_id=$1 AND id=$2 AND state='recording' RETURNING id",[s.encounter,id,state,evidence])==[],do: S.abort(tx,:completion_conflict)
        S.rows(tx,"INSERT INTO device_manifests VALUES($1,$2,$3,now())",[id,digest,m])
        S.rows(tx,"UPDATE device_sessions SET phase='sealed',manifest_digest=$2 WHERE id=$1",[id,digest])
        if :ets.whereis(:mf_live_ecg) != :undefined,do: :ets.delete(:mf_live_ecg,id)
        Barrier.hit("db_completion")
        digest
    end
  end
  def verify_review(enc,id,actor,digest) do
    case S.rows(Postgres,"SELECT m.digest,m.body FROM device_manifests m JOIN device_sessions s ON s.id=m.acquisition_id JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL",[id,enc,actor]) do
      [[^digest,m]] ->
        with {:ok,bytes} <- File.read(Path.join(root(id),"manifest.mej1")),
             true <- S.hash(bytes)==digest and MedEx.CanonicalJSON.encode(m)==bytes,
             true <- Enum.all?(m["streams"],fn {n,v}->
               idx=v["index"]
               with {:ok,spec}<-J.stream_spec(idx["stream"]),
                    {:ok,%{sealed: true,index_digest: actual}}<-MedEx.Storage.File.recover(attempt_dir(id,n,idx["fence"]),stream: spec,fence: idx["fence"]) do
                 actual==v["digest"]
               else _ -> false end
             end) do
          :ok
        else _->{:error,:unverified_manifest} end
      _->{:error,:review_changed}
    end
  end

  defp defects(s) do
    index=s["index"]
    (if index["terminal"]=="finished",do: [],else: ["interrupted"]) ++
      (if s["clock"]["state"]=="bounded",do: [],else: ["clock_unavailable"]) ++ Enum.map(index["spans"],& &1["code"])
  end

  def recover do
    # File paths are owned exclusively by one Exam service. On restart its writer
    # processes are dead. Reconcile only frozen, previously requested finishes.
    for [id,enc,boot,p,site,descriptors,final] <- S.rows(Postgres,"SELECT id,encounter_id,boot,profile,site,descriptors,final_inventory FROM device_sessions WHERE phase='finalizing'",[]) do
      prepare=Postgrex.transaction(Postgres,fn tx->
        S.rows(tx,"SELECT id FROM device_sessions WHERE id=$1 FOR UPDATE",[id])
        stage(tx,id,%{encounter: enc,boot: boot,profile: p,site: site,descriptors: descriptors},final)
      end)
      case prepare do
        {:ok,_} ->
          result=Postgrex.transaction(Postgres,fn tx->
            S.rows(tx,"SELECT id FROM device_sessions WHERE id=$1 FOR UPDATE",[id])
            finalize(tx,id,%{encounter: enc,profile: p})
          end)
          recovery_result(id,result)
        error -> recovery_result(id,error)
      end
      :ok
    end
    :ok
  end

  defp recovery_result(_, {:ok,_}),do: :ok
  defp recovery_result(_, {:error,:inventory_pending}),do: :awaiting_upload
  defp recovery_result(id,{:error,reason}) do
    require Logger
    Logger.error("Device manifest recovery blocked (#{S.hash(id)}): #{inspect(reason,limit: 5)}")
    :blocked
  end

  def install!(file,bytes) do
    dir=Path.dirname(file)
    File.mkdir_p!(dir)
    tmp=file<>"."<>S.nonce()
    try do
      File.open!(tmp,[:write,:binary,:exclusive],fn io-> :ok=IO.binwrite(io,bytes); :ok=:file.sync(io) end)
      :ok=File.ln(tmp,file)
      {:ok,fd}=:file.open(String.to_charlist(dir),[:raw,:read,:directory])
      try do :ok=:file.sync(fd) after :file.close(fd) end
    after
      File.rm(tmp)
    end
  end
end
