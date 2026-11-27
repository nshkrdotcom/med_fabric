defmodule MedFabric.Exam.AcquisitionExpiry do
  @moduledoc "Closes admission before independently quiescing and settling actual source effects."
  use GenServer
  require Logger
  alias MedFabric.Exam.{AcquisitionIngress, AcquisitionManifest}
  alias MedFabric.Store.AcquisitionSessions, as: S
  def start_link(context), do: GenServer.start_link(__MODULE__, context)
  def init(context), do: {:ok, context, {:continue, :start}}

  def handle_continue(:start, context) do
    Process.send_after(self(), :sweep, 2_000)
    {:noreply, context}
  end

  def handle_info(:sweep, context) do
    case expiring(context) do
      {:ok, ids} ->
        Enum.each(ids, &log_settlement(context, &1))

      {:error, _} ->
        Logger.warning("acquisition_expiry_poll_failed")
    end

    Process.send_after(self(), :sweep, 2_000)
    {:noreply, context}
  end

  defp log_settlement(context, id) do
    if sweep_one(context, id) != :ok, do: Logger.warning("acquisition_settlement_pending")
  end

  defp expiring(context) do
    :ok = S.expire_unadmitted(context.db)
    {:ok, S.expiring(context.db)}
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :database_unavailable}
  catch
    :exit, {_, {module, _, _}} when module in [GenServer, DBConnection.Holder] ->
      {:error, :database_unavailable}
  end

  def sweep_one(context, id) do
    with {:ok, {:expire, streams}} <- S.expire(context.db, id),
         :ok <- AcquisitionIngress.quiesce(context, id, streams),
         {:ok, _} <- AcquisitionManifest.settle_interrupted(context, id) do
      try do
        :ets.delete(:mf_live_ecg, :erlang.phash2(id, 64))
      rescue
        ArgumentError -> :ok
      end

      :ok
    else
      {:ok, :current} ->
        :ok

      _ ->
        S.settlement_pending(context.db, id)
        {:error, :settlement_pending}
    end
  rescue
    _ -> {:error, :settlement_outcome_unknown}
  catch
    :exit, {_, {module, _, _}} when module in [GenServer, DBConnection.Holder] ->
      {:error, :settlement_outcome_unknown}
  end
end
