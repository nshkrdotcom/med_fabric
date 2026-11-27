defmodule MedFabric.ExamWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint owned by `med_fabric/apps/exam`.

  Serves the exam LiveView routes, authenticated WebRTC signaling socket, and
  the browser acquisition assets installed in `:mf_exam`.
  """

  use Phoenix.Endpoint, otp_app: :mf_exam

  @session_options [
    store: :cookie,
    key: "_mf_exam_key",
    signing_salt: "mf_exam_sess"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:x_headers, session: @session_options]]
  )

  socket("/socket", MedFabric.ExamWeb.UserSocket,
    websocket: [connect_info: [:x_headers]],
    longpoll: false
  )

  plug(Plug.Static, at: "/assets", from: :mf_exam, only: ~w(exam.js acquisition.js acquisition_worklet.js))
  plug(Plug.Static, at: "/assets", from: {:phoenix, "priv/static"}, only: ~w(phoenix.mjs))

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.esm.js)
  )


  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 65_536,
    read_length: 65_536,
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(MedFabric.ExamWeb.Router)

end
