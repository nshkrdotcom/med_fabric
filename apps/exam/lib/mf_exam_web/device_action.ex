defmodule MedFabric.ExamWeb.DeviceAction do
  @moduledoc "Authenticated clinician actions used by the external clinical-workflow driver."
  import Plug.Conn
  alias MedFabric.Exam
  alias MedFabric.Exam.{DeviceReviews, DeviceWorkflow}
  alias MedFabric.Store.DeviceCommands
  def init(x), do: x

  def call(c, _) do
    p = c.path_params
    actor = get_session(c, :exam_actor)

    if get_session(c, :exam_role) == "clinician" and
         Exam.member?(p["encounter_id"], actor, :clinician) do
      body = c.body_params
      enc = p["encounter_id"]
      id = p["id"]

      case run_action(body["action"], body, enc, id, actor) do
        v when v in [:ok, {:ok, :ok}] ->
          send_resp(c, 200, "saved")

        {:error, :metric_not_exportable} ->
          send_resp(c, 409, "Metric could not be represented for FHIR export")

        _ ->
          send_resp(c, 409, "Review or acquisition state changed")
      end
    else
      send_resp(c, 403, "Clinician access required")
    end
  end

  defp run_action("review", body, enc, id, actor),
    do: DeviceReviews.review_verified(enc, id, actor, body["digest"], body["choice"])

  defp run_action("monitor_gain", body, enc, id, actor),
    do: DeviceCommands.request(enc, id, actor, body["gain"])

  defp run_action("stop", _, enc, id, actor), do: DeviceWorkflow.stop(enc, id, actor)
  defp run_action("deliver", _, enc, id, actor), do: Exam.deliver(enc, id, actor)
  defp run_action(_, _, _, _, _), do: {:error, :invalid_action}
end
