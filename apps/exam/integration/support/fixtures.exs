defmodule MedFabric.Exam.IntegrationFixtures do
  import ExUnit.Callbacks
  alias MedFabric.Store.{Postgres,Encounters,DeviceSessions,AcquisitionSessions}
  @uuid "00000000-0000-4000-8000-000000000002"
  def context(root) do
    url=System.fetch_env!("DATABASE_URL")
    schema="exam_test_"<>Base.encode16(:crypto.strong_rand_bytes(8),case: :lower)
    admin=start_supervised!(Supervisor.child_spec({Postgres,url: url},id: :fixture_admin))
    Postgrex.query!(admin,"CREATE SCHEMA "<>schema,[])
    on_exit(fn->
      {:ok,cleanup}=Postgres.start_link(url: url)
      Postgrex.query!(cleanup,"DROP SCHEMA "<>schema<>" CASCADE",[])
      GenServer.stop(cleanup)
    end)
    db=start_supervised!(Supervisor.child_spec({Postgres,url: url,parameters: [search_path: schema],pool_size: 8},id: :fixture_database))
    {:ok,:ok}=Postgres.migrate(db,@uuid)
    :ok=File.chmod(root,0o700)
    owner=start_supervised!({MedFabric.Exam.DeviceRootLock,name: __MODULE__.Root,root: root,deployment_uuid: @uuid})
    start_supervised!({Registry,keys: :unique,name: __MODULE__.Registry})
    start_supervised!({DynamicSupervisor,strategy: :one_for_one,name: __MODULE__.Writers})
    start_supervised!({Phoenix.PubSub,name: __MODULE__.PubSub})
    MedFabric.Exam.ClockObservations.initialize_host_generation()
    context=%MedFabric.Exam.Context{db: db,artifact_dir: root,root_owner: owner,registry: __MODULE__.Registry,writers: __MODULE__.Writers,pubsub: __MODULE__.PubSub}
    {:ok,:ok}=Encounters.open(db,%{"exam"=>"encounter","patient_actor"=>"patient","clinician_actor"=>"clinician"})
    context
  end
  def device(context,profile \\ "paired_exam") do
    true=DeviceSessions.enroll(context.db,"gateway",String.duplicate("t",48))
    {:ok,:ok}=DeviceSessions.authorize(context.db,"encounter","gateway",profile,"Synthetic anterior site","clinician")
    descriptors=if profile == "plx_spot_check",do: %{},else: Map.new(["audio","ecg"],fn name->{name,MedEx.Serialization.to_map(spec(name,"device_acquisition","gateway","boot"))} end)
    hello=%{"api_revision"=>2,"acquisition"=>"device_acquisition","encounter"=>"encounter","boot"=>"boot","profile"=>profile,"descriptors"=>descriptors}
    {:ok,bind}=AcquisitionSessions.admit(context.db,%{kind: :device,id: "gateway"},hello)
    {bind,hello}
  end
  def browser(context) do
    {:ok,:ok}=Encounters.browser_session(context.db,"patient_session","encounter","patient",:patient)
    {:ok,created}=AcquisitionSessions.create_browser(context.db,"encounter","patient","patient_session","page","creation_request")
    spec=spec("audio",created.acquisition,"patient","page",true)
    hello=%{"api_revision"=>2,"acquisition"=>created.acquisition,"encounter"=>"encounter","boot"=>"page","profile"=>"browser_microphone","creation"=>created.creation,"descriptors"=>%{"audio"=>MedEx.Serialization.to_map(spec)}}
    principal=%{kind: :browser,id: "patient",session: "patient_session"}
    {:ok,bind}=AcquisitionSessions.admit(context.db,principal,hello)
    {bind,spec,hello,principal}
  end
  def spec(name,id,source,boot,browser? \\ false) do
    spec=%MedEx.StreamSpec{acquisition_id: id,source_ref: source,boot_id: boot,stream_id: name,source_epoch: 0,descriptor_ref: "",
      modality: if(browser?,do: "medex:browser_microphone",else: if(name == "audio",do: "medex:diagnostic_audio",else: "medex:ecg")),encoding: :s16le,
      sample_rate: {if(name == "audio",do: 48_000,else: 250),1},channels: [%{id: name,label: name,unit: :unknown,calibration: :unknown}],
      capabilities: %{encodings: [:s16le],max_frame_samples: 960,max_payload_bytes: 1920,replay: if(browser?,do: :none,else: :durable_spool),commands: []}}
    %{spec|descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}
  end
  def frame(sequence \\ 0,first \\ 0) do
    {:ok,raw}=MedEx.Wire.FrameV1.encode(%MedEx.Wire.FrameV1{stream_number: 1,source_epoch: 0,config_epoch: :unknown,sequence: sequence,first_sample: first,sample_count: 2,payload: <<1::little-16,-2::little-signed-16>>})
    raw
  end
  def wait_file(path,deadline \\ nil) do
    deadline=deadline || System.monotonic_time(:millisecond)+10_000
    cond do
      File.exists?(path)->File.read!(path)
      System.monotonic_time(:millisecond)>=deadline->raise "barrier not reached"
      true->Process.sleep(10);wait_file(path,deadline)
    end
  end
end
