defmodule MedFabric.Exam.AcquisitionExpiry do
  @moduledoc "Closes admission before independently quiescing and settling actual source effects."
  use GenServer
  alias MedFabric.Exam.AcquisitionIngress
  alias MedFabric.Store.AcquisitionSessions,as: S
  def start_link(context),do: GenServer.start_link(__MODULE__,context)
  def init(context),do: {:ok,context,{:continue,:start}}
  def handle_continue(:start,context) do Process.send_after(self(),:sweep,2_000); {:noreply,context} end
  def handle_info(:sweep,context) do
    S.expire_unadmitted(context.db)
    Enum.each(S.expiring(context.db),&sweep_one(context,&1))
    Process.send_after(self(),:sweep,2_000)
    {:noreply,context}
  end
  def sweep_one(context,id) do
    with {:ok,{:expire,streams}} <- S.expire(context.db,id),
         :ok <- AcquisitionIngress.quiesce(context,id,streams),
         {:ok,_} <- MedFabric.Exam.AcquisitionManifest.settle_interrupted(context,id) do
      try do :ets.delete(:mf_live_ecg,:erlang.phash2(id,64)) rescue ArgumentError -> :ok end
      :ok
    else
      {:ok,:current}->:ok
      _->S.settlement_pending(context.db,id); {:error,:settlement_pending}
    end
  end
end
