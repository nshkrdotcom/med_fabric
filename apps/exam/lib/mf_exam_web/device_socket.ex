defmodule MedFabric.ExamWeb.DeviceSocket do
  @moduledoc "Device authentication edge; acquisition execution is shared with the browser producer."
  import Plug.Conn
  alias MedFabric.ExamWeb.AcquisitionSocket
  alias MedFabric.Store.DeviceSessions
  def init(kind), do: kind

  def call(conn, kind) do
    context = MedFabric.Exam.context()

    with true <- MedFabric.Exam.lab()[:device_enabled] == true and conn.scheme == :https,
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, id} <- DeviceSessions.authenticate(context.db, token) do
      AcquisitionSocket.upgrade(conn, context, %{kind: :device, id: id}, kind)
    else
      _ -> send_resp(conn, 403, "Device authorization required")
    end
  end
end
