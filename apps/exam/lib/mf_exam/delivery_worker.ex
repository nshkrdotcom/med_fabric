defmodule MedFabric.Exam.DeliveryWorker do
  @moduledoc "One bounded outbox worker. HTTP runs outside Store transactions and acquisition locks."
  use GenServer
  require Logger
  alias MedFabric.Interop.FhirClient
  alias MedFabric.Store.{Deliveries, Encounters}
  def start_link(context), do: GenServer.start_link(__MODULE__, context)

  def init(context) do
    Process.send_after(self(), :work, 250)
    {:ok, context}
  end

  def handle_info(:work, context) do
    case due(context) do
      {:ok, ids} -> Enum.each(ids, &work_one(context, &1))
      {:error, _} -> Logger.warning("delivery_poll_failed")
    end

    Process.send_after(self(), :work, 250)
    {:noreply, context}
  end

  defp due(context) do
    {:ok, Deliveries.due(context.db, 4)}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :database_unavailable}
  catch
    :exit, {_, {module, _, _}} when module in [GenServer, DBConnection.Holder] ->
      {:error, :database_unavailable}
  end

  defp work_one(context, id) do
    case run(context, id) do
      {:error, :invalid_claim_history} ->
        Logger.error("delivery_claim_history_invalid")
        defer(context, id)

      {:error, _} ->
        Logger.warning("delivery_item_outcome_unknown")
        defer(context, id)

      _ ->
        :ok
    end
  end

  defp defer(context, id) do
    Deliveries.defer_failure(context.db, id)
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :database_unavailable}
  catch
    :exit, {_, {module, _, _}} when module in [GenServer, DBConnection.Holder] ->
      {:error, :database_unavailable}
  end

  def run(context, id) do
    with {:ok, intent} <- Deliveries.get(context.db, id) do
      result =
        case intent.status do
          "pending" ->
            prepare(context, intent)

          state when state in ["ready", "retryable"] ->
            dispatch(context, intent)

          "dispatching" ->
            Deliveries.expire_claim(context.db, id)

          "unresolved" ->
            Deliveries.reconcile(
              context.db,
              id,
              FhirClient.reconcile(intent.resource, base_url: intent.destination)
            )

          _ ->
            :idle
        end

      MedFabric.Exam.announce(intent.encounter, context)
      result
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :database_outcome_unknown}
    _ -> {:error, :worker_outcome_unknown}
  catch
    :exit, {_, {module, _, _}} when module in [GenServer, DBConnection.Holder] ->
      {:error, :worker_outcome_unknown}
  end

  defp prepare(context, intent) do
    with {:ok, native} <- Deliveries.observation(context.db, intent.observation),
         {:ok, config} <- Encounters.export(context.db, intent.encounter),
         {:ok, resource} <-
           FhirClient.resource_checked(
             native,
             %{"system" => intent.identifier_system, "value" => intent.identifier_value},
             config.refs
           ) do
      bytes = FhirClient.canonical_bytes(resource)

      Deliveries.save_mapping(context.db, intent.id, %{
        destination: config.destination,
        refs: config.refs,
        version: FhirClient.mapping_version(),
        resource: resource,
        bytes: bytes,
        fingerprint: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
        qualified: config.qualified,
        qualification_ref: config.qualification_ref
      })
    else
      {:error, reason} -> Deliveries.block_preparation(context.db, intent.id, reason)
    end
  end

  defp dispatch(context, intent) do
    with {:ok, claim} <- Deliveries.claim_delivery(context.db, intent.id),
         {:ok, :ok} <- Deliveries.before_dispatch(context.db, claim) do
      result =
        FhirClient.deliver(claim.resource,
          base_url: claim.destination,
          pinned_bytes: claim.resource_bytes
        )

      Deliveries.record_attempt_outcome(context.db, claim, result)
    end
  end
end
