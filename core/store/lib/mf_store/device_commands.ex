defmodule MedFabric.Store.DeviceCommands do
  @moduledoc "Device grant authority and durable command attempts; MedEx owns technical decisions."
  alias MedFabric.Store.AcquisitionSessions, as: S
  alias MedEx.ControlInterlock

  def request(db,enc,id,actor,gain) when gain in ["unity","half"] do
    Postgrex.transaction(db,fn tx ->
      S.writable!(tx)
      s=S.snapshot!(tx,id,:share)
      unless s.encounter == enc and s.clinician == actor and is_nil(s.closed_at),do: S.abort(tx,:unauthorized)
      S.rows(tx,"SELECT id FROM acquisition_sessions WHERE id=$1 FOR NO KEY UPDATE",[id])
      S.authorize_source!(tx,s)
      unless s.encounter == enc and s.profile == "paired_exam" and s.state == "capturing" and s.authority == "authorized",do: S.abort(tx,:inactive)
      unless S.rows(tx,"SELECT id FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching','outcome_unknown')",[id]) == [],do: S.abort(tx,:reconciliation_required)
      [[epoch]]=S.rows(tx,"SELECT COALESCE(MAX((result->>'epoch')::bigint),0) FROM device_commands WHERE acquisition_id=$1 AND state='applied'",[id])
      watermarks=Map.new(S.rows(tx,"SELECT DISTINCT ON(stream) stream,COALESCE((receipt->>'durable_sample')::bigint,0) FROM stream_attempts WHERE acquisition_id=$1 ORDER BY stream,generation DESC",[id]),fn [name,n] -> {name,n} end)
      request=%{"id"=>S.nonce(),"actor"=>actor,"boot"=>s.boot,"generation"=>to_string(s.generation),"op"=>"set_monitor_gain","target"=>"handheld_monitor","expected_epoch"=>to_string(epoch),"gain"=>gain,"watermarks"=>Map.new(watermarks,fn {k,v}->{k,to_string(v)} end)}
      fingerprint=S.hash(MedEx.CanonicalJSON.encode(request))
      state=%ControlInterlock{target: "handheld_monitor",boot_id: s.boot,current_epoch: epoch,generation: s.generation}
      with {:ok,_,_} <- ControlInterlock.request(state,command(request,fingerprint),watermarks) do
        S.rows(tx,"INSERT INTO device_commands(id,acquisition_id,fingerprint,request,state,expires_at) VALUES($1,$2,$3,$4,'requested',clock_timestamp()+interval '30 seconds')",[request["id"],id,fingerprint,request])
        S.fact(tx,id,"command_requested",Map.put(request,"fingerprint",fingerprint))
      else _ -> S.abort(tx,:invalid_command) end
    end)
  end
  def request(_,_,_,_,_),do: {:error,:invalid_command}

  def poll(db,bind,nonce) do
    S.scoped(db,bind,fn tx,s ->
      base=%{"type"=>"heartbeat_reply","nonce"=>nonce,"boot"=>s.boot,"generation"=>to_string(s.generation),"remaining_ms"=>S.authority_ms(tx,s.id)}
      case S.rows(tx,"SELECT id,fingerprint,request,state,GREATEST(0,FLOOR(EXTRACT(EPOCH FROM (expires_at-clock_timestamp()))*1000))::integer,updated_at<=clock_timestamp()-interval '3 seconds' FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching','outcome_unknown') ORDER BY updated_at LIMIT 1 FOR UPDATE",[s.id]) do
        [[id,fp,request,state,command_ms,timed_out]] ->
          remaining=min(base["remaining_ms"],command_ms)
          cond do
            state == "requested" and remaining>0 and request["generation"] == to_string(s.generation) ->
              interlock=interlock(request,fp,:requested)
              with {:ok,_,_} <- ControlInterlock.step(interlock,{:intent_committed,id}) do
                transition(tx,s.id,id,"dispatching",nil)
                Map.merge(base,%{"type"=>"command","command"=>Map.put(request,"fingerprint",fp),"command_remaining_ms"=>remaining})
              else _ -> S.abort(tx,:invalid_command_state) end
            state == "requested" -> transition(tx,s.id,id,"rejected",%{"reason"=>"expired_before_dispatch"}); base
            state == "dispatching" and timed_out ->
              with {:ok,_,_} <- ControlInterlock.step(interlock(request,fp,:dispatched),{:timeout,id}) do
                transition(tx,s.id,id,"outcome_unknown",nil)
                Map.merge(base,%{"type"=>"state_query","id"=>id,"fingerprint"=>fp,"command"=>Map.put(request,"fingerprint",fp),"command_remaining_ms"=>0})
              else _ -> S.abort(tx,:invalid_command_state) end
            state == "outcome_unknown" ->
              if S.rows(tx,"UPDATE device_commands SET readback_count=readback_count+1,updated_at=clock_timestamp() WHERE id=$1 AND readback_count<3 AND updated_at<clock_timestamp()-interval '1 second' RETURNING id",[id]) == [[id]],
                do: Map.merge(base,%{"type"=>"state_query","id"=>id,"fingerprint"=>fp,"command"=>Map.put(request,"fingerprint",fp),"command_remaining_ms"=>0}),else: base
            true -> base
          end
        [] -> base
      end
    end)
  end

  def result(db,bind,result) when is_map(result) do
    S.scoped(db,bind,fn tx,s ->
      unless s.state == "capturing" and is_nil(s.frozen_at),do: S.abort(tx,:frozen_evidence)
      case S.rows(tx,"SELECT request,fingerprint,state,result FROM device_commands WHERE acquisition_id=$1 AND id=$2 FOR UPDATE",[s.id,result["id"]]) do
        [[_,_,_,^result]] -> :ok
        [[request,fp,state,_]] when state in ["dispatching","outcome_unknown"] ->
          unless result["gain"] == request["gain"] and result["expected_epoch"] == request["expected_epoch"],do: S.abort(tx,:command_conflict)
          technical=historical(result)
          phase=if state == "dispatching",do: :dispatched,else: :outcome_unknown
          with {:ok,_,_} <- ControlInterlock.step(interlock(request,fp,phase),{:historical_result,technical}) do
            outcome=case technical.outcome do :applied -> "applied"; :rejected -> "rejected"; :outcome_unknown -> "outcome_unknown" end
            transition(tx,s.id,result["id"],outcome,result)
          else _ -> S.abort(tx,:command_conflict) end
        _ -> S.abort(tx,:command_conflict)
      end
    end)
  end
  def result(_,_,_),do: {:error,:invalid_result}

  def close_pending(tx,id) do
    for [command,state] <- S.rows(tx,"SELECT id,state FROM device_commands WHERE acquisition_id=$1 AND state IN ('requested','dispatching') FOR UPDATE",[id]) do
      if state == "requested",do: transition(tx,id,command,"rejected",%{"reason"=>"collection_ended_before_dispatch"}),else: transition(tx,id,command,"outcome_unknown",%{"reason"=>"collection_ended"})
    end
    :ok
  end
  defp interlock(request,fp,phase),do: %ControlInterlock{target: request["target"],boot_id: request["boot"],generation: String.to_integer(request["generation"]),current_epoch: String.to_integer(request["expected_epoch"]),pending: %{command: command(request,fp),phase: phase,watermarks: Map.new(request["watermarks"],fn {k,v}->{k,String.to_integer(v)} end)}}
  defp command(r,fp),do: %{id: r["id"],fingerprint: fp,boot_id: r["boot"],target: r["target"],generation: String.to_integer(r["generation"]),expected_epoch: String.to_integer(r["expected_epoch"]),value: r["gain"],expired: false}
  defp historical(r) do
    status=case r["status"] do "applied" -> :applied; "rejected" -> :rejected; _ -> :outcome_unknown end
    application=r["application"] || %{}
    %{id: r["id"],fingerprint: r["fingerprint"],boot_id: r["boot"],target: r["target"],generation: counter(r["generation"]),outcome: status,epoch: counter(r["epoch"]),application: %{observed_at: counter(application["observed_at"]),first_sample: if(application["first_sample"] == "unknown",do: :unknown,else: counter(application["first_sample"]))},reason: r["reason"] || ""}
  end
  defp counter(s),do: case MedFabric.Domain.Review.counter(s) do {:ok,n}->n; _ -> :invalid end
  defp transition(tx,acq,id,state,result) do
    S.rows(tx,"UPDATE device_commands SET state=$2,result=$3,updated_at=clock_timestamp() WHERE id=$1",[id,state,result])
    S.fact(tx,acq,"command_"<>state,Map.put(result || %{},"id",id))
  end
end
