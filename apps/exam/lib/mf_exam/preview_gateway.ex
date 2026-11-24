defmodule MedFabric.Exam.PreviewGateway do
  @moduledoc "Disposable feed. One in-flight request and one latest replacement per active source."
  use GenServer
  def start_link(_),do: GenServer.start_link(__MODULE__,nil,name: __MODULE__)
  def init(_) do
    :ets.new(:mf_live_ecg,[:named_table,:set,:public,write_concurrency: true])
    :ets.new(__MODULE__,[:named_table,:set,:public,write_concurrency: true])
    Process.send_after(self(),:drain,10)
    {:ok,nil}
  end
  def feed(id,raw) do
    if Application.get_env(:mf_exam,:sidecar),do: :ets.insert(__MODULE__,{id,System.monotonic_time(:millisecond),raw})
    :ok
  end
  def handle_info(:drain,s) do
    for {id,_,_}<-:ets.tab2list(__MODULE__) do
      case :ets.take(__MODULE__,id) do
        [{_,at,raw}]->if System.monotonic_time(:millisecond)-at<=200,do: request("feed",id,raw,"application/octet-stream")
        _->:ok
      end
    end
    Process.send_after(self(),:drain,10);{:noreply,s}
  end
  def viewer(id,actor) do
    with %{secret: key}<-Application.get_env(:mf_exam,:sidecar) do
      bytes=JSON.encode!(%{"acquisition"=>id,"viewer"=>actor,"exp"=>System.system_time(:second)+60})
      Base.url_encode64(bytes,padding: false)<>"."<>Base.url_encode64(:crypto.mac(:hmac,:sha256,key,bytes),padding: false)
    end
  end
  def request(path,id,body,ct) do
    with %{url: url,secret: key}<-Application.get_env(:mf_exam,:sidecar),
         {:ok,%{status: 200,body: out}}<-Req.post(url<>"/"<>path,body: body,headers: [{"authorization","Bearer "<>key},{"x-acquisition",id},{"content-type",ct}],
           retry: false,receive_timeout: if(path=="offer",do: 8000,else: 200),decode_body: false) do
      {:ok,out}
    else _->{:error,:preview_unavailable} end
  end
end

defmodule MedFabric.ExamWeb.DevicePreview do
  import Plug.Conn
  alias MedFabric.Exam.{PreviewGateway,ICE}
  alias MedFabric.Store.{Postgres,DeviceSessions}
  def init(o),do: o
  def call(c,_) do
    p=c.path_params; actor=get_session(c,:exam_actor); op=c.body_params["operation"]
    with "clinician"<-get_session(c,:exam_role),true<-op in ["offer","close","status"],
         [[_]]<-DeviceSessions.rows(Postgres,"SELECT s.id FROM device_sessions s JOIN encounters e ON e.id=s.encounter_id WHERE s.id=$1 AND e.id=$2 AND e.clinician_actor=$3 AND e.closed_at IS NULL AND s.phase='capturing'",[p["id"],p["encounter_id"],actor]),
         token when is_binary(token)<-PreviewGateway.viewer(p["id"],actor),
         sdp=c.body_params["sdp"] || "",true<-is_binary(sdp) and byte_size(sdp)<=32768,
         ice=ICE.config(actor,MedFabric.Exam.lab().turn),
         {:ok,bytes}<-PreviewGateway.request(op,p["id"],JSON.encode!(%{"token"=>token,"sdp"=>sdp,"ice"=>ice}),"application/json") do
      c |> put_resp_content_type("application/json") |> send_resp(200,bytes)
    else _->send_resp(c,503,"Preview unavailable") end
  end
end
