defmodule MedFabric.ExamWeb.DeviceAction do
  @moduledoc "Authenticated clinician actions used by the external clinical-workflow driver."
  import Plug.Conn
  alias MedFabric.Exam
  alias MedFabric.Exam.{DeviceWorkflow,DeviceReviews}
  alias MedFabric.Store.DeviceCommands
  def init(x),do: x
  def call(c,_) do
    p=c.path_params; actor=get_session(c,:exam_actor)
    if get_session(c,:exam_role)=="clinician" and Exam.member?(p["encounter_id"],actor,:clinician) do
      body=c.body_params;enc=p["encounter_id"];id=p["id"]
      result=case body["action"] do
        "review"->DeviceReviews.review_verified(enc,id,actor,body["digest"],body["choice"])
        "monitor_gain"->DeviceCommands.request(enc,id,actor,body["gain"])
        "stop"->DeviceWorkflow.stop(enc,id,actor)
        "deliver"->Exam.deliver(enc,id,actor)
        _->{:error,:invalid_action}
      end
      case result do
        v when v in [:ok,{:ok,:ok}]->send_resp(c,200,"saved")
        _->send_resp(c,409,"Review or acquisition state changed")
      end
    else send_resp(c,403,"Clinician access required") end
  end
end
