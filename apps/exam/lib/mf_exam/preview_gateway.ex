defmodule MedFabric.Exam.PreviewGateway do
  @moduledoc "Disposable latest-only relay after authoritative commit. No media providers live in Exam."
  use GenServer
  @cap 64
  def start_link(config),do: GenServer.start_link(__MODULE__,config,name: __MODULE__)
  def init(config) do
    :ets.new(__MODULE__,[:named_table,:set,:public,write_concurrency: true])
    Process.send_after(self(),:drain,10)
    {:ok,config}
  end
  def feed(bind,spec,raw) do
    try do
      slot=:erlang.phash2(bind.id,@cap)
      if is_binary(raw) and byte_size(raw)<=65_584,do: :ets.insert(__MODULE__,{slot,bind.id,System.monotonic_time(:millisecond),bind.generation,spec.source_epoch,spec.descriptor_ref,raw})
    rescue ArgumentError -> :ok end
    :ok
  end
  def handle_info(:drain,config) do
    case :ets.first(__MODULE__) do
      :'$end_of_table' -> :ok
      id ->
        case :ets.take(__MODULE__,id) do
          [{_,id,at,generation,epoch,descriptor,raw}] ->
            if System.monotonic_time(:millisecond)-at<=200 do
              request(config,"feed",id,raw,"application/octet-stream",[{"x-generation",to_string(generation)},{"x-source-epoch",to_string(epoch)},{"x-descriptor-ref",descriptor}])
            end
          _ -> :ok
        end
    end
    Process.send_after(self(),:drain,10)
    {:noreply,config}
  end
  def capability(config,snapshot,actor,session) do
    now=System.system_time(:millisecond)
    audio=snapshot.descriptors["audio"]
    claims=%{"purpose"=>"monitor","acquisition"=>snapshot.id,"source_kind"=>snapshot.source_kind,
      "profile"=>snapshot.profile,"generation"=>to_string(snapshot.generation),"source_epoch"=>audio["source_epoch"],
      "descriptor_ref"=>audio["descriptor_ref"],"viewer"=>actor,"viewer_session"=>session,
      "issued_at_ms"=>to_string(now),"expires_at_ms"=>to_string(now+snapshot.preview_remaining_ms),
      "nonce"=>MedFabric.Store.AcquisitionSessions.nonce()}
    bytes=MedEx.CanonicalJSON.encode(claims)
    Base.url_encode64(bytes,padding: false)<>"."<>Base.url_encode64(:crypto.mac(:hmac,:sha256,config.secret,bytes),padding: false)
  end
  def request(config,path,id,body,content_type,headers \\ []) when path in ["feed","offer","status","close","renew"] do
    case Req.post(config.url<>"/"<>path,body: body,
      headers: [{"authorization","Bearer "<>config.secret},{"x-acquisition",id},{"content-type",content_type}|headers],
      retry: false,redirect: false,receive_timeout: if(path == "offer",do: 8_000,else: 200),decode_body: false,into: &bounded_body/2) do
      {:ok,%{status: 200,body: bytes}} when is_binary(bytes) and byte_size(bytes)<=65_536 -> {:ok,bytes}
      _ -> {:error,:preview_unavailable}
    end
  end
  defp bounded_body({:data,data},{request,response}) do
    body=response.body || ""
    if byte_size(body)+byte_size(data)<=65_536,
      do: {:cont,{request,%{response|body: body<>data}}},else: {:halt,{request,%{response|status: 502,body: ""}}}
  end
  defp bounded_body(_,pair),do: {:cont,pair}
end

defmodule MedFabric.ExamWeb.DevicePreview do
  @moduledoc false
  import Plug.Conn
  alias MedFabric.Exam.PreviewGateway
  def init(opts),do: opts
  def call(conn,_) do
    actor=get_session(conn,:exam_actor)
    session=get_session(conn,:exam_session)
    p=conn.path_params
    op=conn.body_params["operation"]
    sdp=conn.body_params["sdp"] || ""
    with "clinician" <- get_session(conn,:exam_role),true <- op in ["offer","status","close","renew"],
         true <- is_binary(sdp) and byte_size(sdp)<=32_768,
         %{url: _,secret: _}=config <- Application.get_env(:mf_exam,:sidecar),
         {:ok,snapshot} <- MedFabric.Store.AcquisitionSessions.preview_authority(MedFabric.Exam.context().db,p["encounter_id"],p["id"],actor,session),
         token=PreviewGateway.capability(config,snapshot,actor,session),
         {:ok,bytes} <- PreviewGateway.request(config,op,p["id"],JSON.encode!(%{"token"=>token,"sdp"=>sdp}),"application/json") do
      conn |> put_resp_header("cache-control","no-store") |> put_resp_content_type("application/json") |> send_resp(200,bytes)
    else _ -> send_resp(conn,503,"Preview unavailable") end
  end
end
