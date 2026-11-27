defmodule MedFabric.ExamWeb.DeviceAction do
  @moduledoc false
  import Plug.Conn
  alias MedFabric.Exam
  def init(opts), do: opts

  def call(conn, operation) do
    enc = conn.path_params["encounter_id"]
    id = conn.path_params["id"]
    actor = get_session(conn, :exam_actor)
    body = if operation == :deliver, do: %{"action" => "deliver"}, else: conn.body_params
    context = Exam.context()

    with "clinician" <- get_session(conn, :exam_role),
         true <-
           MedFabric.Store.Encounters.session_authorized?(
             context.db,
             get_session(conn, :exam_session),
             enc,
             actor,
             :clinician,
             :read
           ),
         {:ok, result} <- action(body, context, enc, id, actor) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{status: "saved", result: result}))
    else
      _ -> send_resp(conn, 409, "Action refused")
    end
  end

  defp action(%{"action" => "review"} = b, c, e, id, a),
    do:
      MedFabric.Exam.AcquisitionReviews.review(
        c,
        e,
        id,
        a,
        b["digest"],
        b["request_id"],
        b["choice"]
      )

  defp action(%{"action" => "monitor_gain", "gain" => gain}, c, e, id, a),
    do: MedFabric.Store.DeviceCommands.request(c.db, e, id, a, gain)

  defp action(%{"action" => "stop"}, c, e, id, a),
    do: MedFabric.Exam.AcquisitionWorkflow.stop(c, e, id, a)

  defp action(%{"action" => "deliver"}, c, e, id, a), do: Exam.deliver(e, id, a, c)
  defp action(_, _, _, _, _), do: {:error, :invalid_action}
end
