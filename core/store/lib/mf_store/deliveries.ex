defmodule MedFabric.Store.Deliveries do
  @moduledoc "Pinned native outbox and separate dispatch/confirmation predicates. Claims fence SQL completion, never HTTP."
  alias MedFabric.Store.AcquisitionSessions, as: S
  @delays [5,30,120,600,1800]
  @fields "id,encounter_id,observation_id,identifier_system,identifier_value,status,destination,references_json,mapping_version,resource,resource_bytes,fingerprint,conditional_qualified,qualification_ref,claim_token,attempt_id,lease_until,remote_ref,executions,proof"
  @keys ~w(id encounter observation identifier_system identifier_value status destination refs mapping_version resource resource_bytes fingerprint conditional_qualified qualification_ref token attempt_id lease_until remote_ref executions proof)a

  def get(db,id), do: case S.rows(db,"SELECT "<>@fields<>" FROM outbox_deliveries WHERE id=$1",[id]) do
    [row] -> {:ok,Map.new(Enum.zip(@keys,row))}
    _ -> {:error,:intent_missing}
  end
  def due(db,limit \\ 4), do: for [id] <- S.rows(db,"SELECT id FROM outbox_deliveries WHERE next_due_at<=clock_timestamp() AND status IN ('pending','ready','retryable','unresolved','dispatching') ORDER BY next_due_at LIMIT $1",[min(limit,4)]), do: id
  def observation(db,id), do: case S.rows(db,"SELECT body FROM observations WHERE id=$1",[id]) do [[body]] -> {:ok,body}; _ -> {:error,:observation_missing} end

  def dispatch_allowed?(attempts,qualified) when is_list(attempts) do
    attempts == [] or Enum.all?(attempts,&settled_noncommit?/1) or
      (qualified and Enum.all?(attempts,&(&1.protected or settled_noncommit?(&1))))
  end
  def confirmation_allowed?(attempts,qualified) when is_list(attempts),
    do: Enum.all?(attempts,fn attempt -> attempt.outcome in ["noncommitted","matched","settled"] or (qualified and attempt.protected) end)
  defp settled_noncommit?(attempt), do: attempt.outcome == "noncommitted"

  def save_mapping(db,id,mapping) do
    locked(db,id,fn tx,d ->
      unless d.status in ["pending","blocked"] and is_nil(d.fingerprint) and attempts(tx,id) == [], do: S.abort(tx,:mapping_pinned)
      unless is_binary(mapping.bytes) and byte_size(mapping.bytes)<=1_048_576 and S.hash(mapping.bytes) == mapping.fingerprint and
        mapping.resource["identifier"] == [%{"system"=>d.identifier_system,"value"=>d.identifier_value}],do: S.abort(tx,:invalid_mapping_identity)
      S.rows(tx,"UPDATE outbox_deliveries SET destination=$2,references_json=$3,mapping_version=$4,resource=$5,resource_bytes=$6,fingerprint=$7,conditional_qualified=$8,qualification_ref=$9,status='ready',last_error=NULL,next_due_at=clock_timestamp() WHERE id=$1",[id,mapping.destination,mapping.refs,mapping.version,mapping.resource,mapping.bytes,mapping.fingerprint,mapping.qualified,mapping.qualification_ref])
      :ok
    end)
  end
  def block_preparation(db,id,code), do: locked(db,id,fn tx,d ->
    unless d.status in ["pending","blocked"] and is_nil(d.fingerprint), do: S.abort(tx,:mapping_pinned)
    S.rows(tx,"UPDATE outbox_deliveries SET status='blocked',last_error=$2,next_due_at=NULL WHERE id=$1",[id,safe_code(code)])
    :ok
  end)

  def claim_delivery(db,id) do
    locked(db,id,fn tx,d ->
      S.writable!(tx)
      prior=attempts(tx,id)
      unless d.status in ["ready","retryable"] and dispatch_allowed?(prior,d.conditional_qualified), do: S.abort(tx,:unsafe_dispatch)
      token=S.nonce()
      attempt=S.nonce()
      S.rows(tx,"UPDATE outbox_deliveries SET status='dispatching',claim_token=$2,attempt_id=$3,lease_until=clock_timestamp()+interval '15 seconds',next_due_at=clock_timestamp()+interval '15 seconds' WHERE id=$1",[id,token,attempt])
      append(tx,id,attempt,token,"claim","admitted",d.conditional_qualified,nil)
      %{d | status: "dispatching",token: token,attempt_id: attempt}
    end)
  end

  def before_dispatch(db,claim) do
    locked(db,claim.id,fn tx,d ->
      S.writable!(tx)
      require_claim!(tx,d,claim)
      unless is_binary(d.resource_bytes) and S.hash(d.resource_bytes) == d.fingerprint,do: S.abort(tx,:pinned_resource_corrupt)
      prior=Enum.reject(attempts(tx,d.id),&(&1.id == claim.attempt_id))
      unless dispatch_allowed?(prior,d.conditional_qualified), do: S.abort(tx,:unsafe_dispatch)
      append(tx,d.id,claim.attempt_id,claim.token,"send","possible_send",d.conditional_qualified,nil)
      :ok
    end)
  end

  def record_attempt_outcome(db,claim,outcome) do
    locked(db,claim.id,fn tx,d ->
      if d.status == "confirmed", do: S.abort(tx,:already_confirmed)
      require_claim!(tx,d,claim)
      {fact,ref,code}=case outcome do
        {:matched,remote} when is_binary(remote) -> {"matched",remote,nil}
        {:noncommitted,reason} when reason in [:before_http,:qualified_remote_noncommit] -> {"noncommitted",nil,to_string(reason)}
        {:permanent_noncommit,reason} when reason in [:before_http,:qualified_remote_noncommit] -> {"noncommitted",nil,"permanent_noncommit"}
        {:conflict,reason} -> {"conflict",nil,safe_code(reason)}
        _ -> {"unknown",nil,"outcome_unknown"}
      end
      append(tx,d.id,claim.attempt_id,claim.token,"result",fact,d.conditional_qualified,code)
      prior=attempts(tx,d.id)
      status=cond do
        fact == "conflict" -> "conflict"
        fact == "matched" and confirmation_allowed?(prior,d.conditional_qualified) -> "confirmed"
        code == "permanent_noncommit" and Enum.all?(prior,&settled_noncommit?/1) -> "blocked"
        dispatch_allowed?(prior,d.conditional_qualified) -> "retryable"
        true -> "unresolved"
      end
      proof=%{"safe_confirmation"=>status == "confirmed","basis"=>if(d.conditional_qualified,do: "qualified_conditional_create",else: "all_effects_settled"),"attempt"=>claim.attempt_id}
      persist_outcome(tx,d,status,ref,proof,code)
      status
    end)
  end

  def expire_claim(db,id), do: locked(db,id,fn tx,d ->
    if d.status == "dispatching" and S.rows(tx,"SELECT lease_until IS NULL OR lease_until<=clock_timestamp() FROM outbox_deliveries WHERE id=$1",[id]) == [[true]] do
      persist_outcome(tx,d,"unresolved",nil,%{"safe_confirmation"=>false,"basis"=>"expired_claim"},"claim_expired")
      :unresolved
    else :current end
  end)

  def reconcile(db,id,result) do
    locked(db,id,fn tx,d ->
      unless d.status in ["unresolved","conflict","retryable"], do: S.abort(tx,:not_reconcilable)
      history=attempts(tx,id)
      {status,remote}=case result do
        {:matched,ref} when is_binary(ref) -> if confirmation_allowed?(history,d.conditional_qualified),do: {"confirmed",ref},else: {if(d.status == "conflict",do: "conflict",else: "unresolved"),nil}
        {:conflict,_} -> {"conflict",nil}
        _ -> cond do
          d.status == "conflict" -> {"conflict",nil}
          dispatch_allowed?(history,d.conditional_qualified) -> {"retryable",nil}
          true -> {"unresolved",nil}
        end
      end
      proof=%{"safe_confirmation"=>status == "confirmed","basis"=>if(d.conditional_qualified,do: "qualified_conditional_create",else: "all_effects_settled")}
      persist_outcome(tx,d,status,remote,proof,if(status == "confirmed",do: nil,else: "reconciliation_incomplete"))
      status
    end)
  end

  def remediate(db,id,actor) do
    locked(db,id,fn tx,d ->
      S.authorize_encounter!(tx,d.encounter,actor,:clinician,:read)
      unless d.status in ["blocked","retryable","unresolved"], do: S.abort(tx,:not_remediable)
      state=cond do
        is_nil(d.fingerprint) -> "pending"
        dispatch_allowed?(attempts(tx,id),d.conditional_qualified) -> "retryable"
        true -> "unresolved"
      end
      S.rows(tx,"UPDATE outbox_deliveries SET status=$2,next_due_at=clock_timestamp(),executions=0 WHERE id=$1",[id,state])
      state
    end)
  end

  def authorize(db,id,enc,actor), do: locked(db,id,fn tx,d ->
    unless d.encounter == enc, do: S.abort(tx,:unauthorized)
    S.authorize_encounter!(tx,enc,actor,:clinician,:read)
    :ok
  end)

  defp persist_outcome(tx,d,status,remote,proof,code) do
    next=if status in ["retryable","unresolved"] and d.executions<5,do: Enum.at(@delays,d.executions),else: nil
    executions=if next,do: d.executions+1,else: d.executions
    S.rows(tx,"UPDATE outbox_deliveries SET status=$2,remote_ref=COALESCE($3,remote_ref),proof=$4,last_error=$5,next_due_at=CASE WHEN $6::integer IS NULL THEN NULL ELSE clock_timestamp()+$6*interval '1 second' END,executions=$7,claim_token=NULL,lease_until=NULL WHERE id=$1",[d.id,status,remote,proof,code,next,executions])
  end
  defp require_claim!(tx,d,c) do
    unless d.status == "dispatching" and d.token == c.token and d.attempt_id == c.attempt_id and S.rows(tx,"SELECT lease_until>clock_timestamp() FROM outbox_deliveries WHERE id=$1",[d.id]) == [[true]], do: S.abort(tx,:stale_attempt)
  end
  defp append(tx,id,attempt,token,stage,outcome,protected,reference), do: S.rows(tx,"INSERT INTO delivery_attempts(delivery_id,attempt_id,token,stage,outcome,conditional_protected,evidence_ref) VALUES($1,$2,$3,$4,$5,$6,$7) ON CONFLICT(delivery_id,attempt_id,stage) DO NOTHING",[id,attempt,token,stage,outcome,protected,reference])
  defp attempts(tx,id),do: for [attempt,outcome,protected] <- S.rows(tx,"SELECT DISTINCT ON(attempt_id) attempt_id,outcome,conditional_protected FROM delivery_attempts WHERE delivery_id=$1 ORDER BY attempt_id,ordinal DESC",[id]),do: %{id: attempt,outcome: outcome,protected: protected}
  defp locked(db,id,fun),do: Postgrex.transaction(db,fn tx ->
    case S.rows(tx,"SELECT encounter_id FROM outbox_deliveries WHERE id=$1",[id]) do
      [[enc]] -> S.rows(tx,"SELECT id FROM encounters WHERE id=$1 FOR UPDATE",[enc])
      _ -> S.abort(tx,:intent_missing)
    end
    case S.rows(tx,"SELECT "<>@fields<>" FROM outbox_deliveries WHERE id=$1 FOR UPDATE",[id]) do
      [row] -> fun.(tx,Map.new(Enum.zip(@keys,row)))
      _ -> S.abort(tx,:intent_missing)
    end
  end)
  defp safe_code(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_code(_), do: "delivery_error"
end
