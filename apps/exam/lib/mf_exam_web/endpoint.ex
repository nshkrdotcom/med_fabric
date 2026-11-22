defmodule MedFabric.ExamWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint owned by `med_fabric/apps/exam`.

  Serves the exam LiveView routes, authenticated WebRTC signaling socket, and
  the browser JavaScript hook asset shipped by the single Welded `:med_ex` SDK.
  """

  use Phoenix.Endpoint, otp_app: :mf_exam

  @session_options [
    store: :cookie,
    key: "_mf_exam_key",
    signing_salt: "mf_exam_sess"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  socket "/socket", MedFabric.ExamWeb.UserSocket,
    websocket: true,
    longpoll: false

  plug :serve_med_ex_hook
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug Plug.Session, @session_options
  plug MedFabric.ExamWeb.Router

  defp serve_med_ex_hook(%Plug.Conn{request_path: "/med_ex/session_hook.js"} = conn, _opts) do
    path = MedWeb.Signaling.hook_asset_full_path()

    conn
    |> Plug.Conn.put_resp_content_type("application/javascript")
    |> Plug.Conn.send_file(200, path)
    |> Plug.Conn.halt()
  end

  defp serve_med_ex_hook(conn, _opts), do: conn
end
