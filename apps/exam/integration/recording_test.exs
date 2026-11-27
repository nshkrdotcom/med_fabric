Code.require_file("support/fixtures.exs",__DIR__)
defmodule MedFabric.Exam.AcquisitionRuntimeTest do
  use ExUnit.Case,async: false
  alias MedFabric.Exam.{IntegrationFixtures,AcquisitionIngress,AcquisitionManifest,AcquisitionWorkflow,AcquisitionExpiry}
  alias MedFabric.Store.{AcquisitionSessions,Encounters}
  alias MedEx.Receipt

  @tag :tmp_dir
  test "browser common stream drains durable source, seals exact manifest and verifies individual playback",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,_,_}=IntegrationFixtures.browser(c)
    assert {:ok,ingress,%{receipt: initial}}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
    assert initial.durable_sample == 0
    assert {:ok,%{receipt: accepted}}=AcquisitionIngress.call(ingress,{:frame,IntegrationFixtures.frame()})
    refute Receipt.durable?(accepted)
    assert {:ok,%{receipt: durable}}=AcquisitionIngress.call(ingress,:checkpoint)
    assert durable.durable_sample == 2
    assert {:ok,%{terminal: true,receipt: terminal}}=AcquisitionIngress.call(ingress,{:finish,"1","2",nil})
    assert terminal.journal_generation == durable.journal_generation+1
    assert {:ok,digest}=AcquisitionManifest.finish(c,bind,%{})
    assert {:ok,^digest}=AcquisitionManifest.finish(c,bind,%{})
    {:ok,manifest}=AcquisitionManifest.promoted(c,"encounter",bind.id,"clinician",digest)
    [segment]=manifest["streams"]["audio"]["index"]["segments"]
    assert {:ok,^spec,_,<<1::little-16,-2::little-signed-16>>}=AcquisitionWorkflow.segment(c,"encounter",bind.id,"clinician",digest,"audio",segment["first_sample"],segment["sha256"])
    assert {:error,_}=AcquisitionWorkflow.segment(c,"encounter",bind.id,"patient",digest,"audio",segment["first_sample"],segment["sha256"])
    assert {:error,_}=AcquisitionWorkflow.segment(c,"encounter",bind.id,"clinician",String.duplicate("0",64),"audio",segment["first_sample"],segment["sha256"])
    file=Path.join(AcquisitionManifest.attempt_dir(c,bind.id,"audio",terminal.fence),segment["key"])
    File.write!(file,<<0,0,0,0>>)
    assert {:error,_}=AcquisitionWorkflow.segment(c,"encounter",bind.id,"clinician",digest,"audio",segment["first_sample"],segment["sha256"])
  end

  @tag :tmp_dir
  test "unknown SQL observation after journal commit retires owner and returns actual prefix on fresh binding",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,hello,principal}=IntegrationFixtures.browser(c)
    barriers=Path.join(root,"barriers")
    File.mkdir_p!(barriers)
    Application.put_env(:mf_exam,:barriers,barriers)
    on_exit(fn->Application.delete_env(:mf_exam,:barriers) end)
    parent=self()
    task=Task.async(fn->
      {:ok,owner,_}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
      {:ok,_}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame()})
      send(parent,:accepted)
      receive do :checkpoint->AcquisitionIngress.call(owner,:checkpoint) end
    end)
    assert_receive :accepted,10_000
    File.write!(Path.join(barriers,"journal_sync.audio.armed"),"")
    send(task.pid,:checkpoint)
    backend=Path.join(barriers,"journal_sync.audio.reached") |> IntegrationFixtures.wait_file() |> String.to_integer()
    assert [[true]]=AcquisitionSessions.rows(c.db,"SELECT pg_terminate_backend($1)",[backend])
    File.rm!(Path.join(barriers,"journal_sync.audio.reached"))
    assert {:error,:outcome_unknown}=Task.await(task,40_000)
    {:ok,fresh}=AcquisitionSessions.admit(c.db,principal,hello)
    assert {:ok,owner,%{receipt: recovered,handoff: handoff}}=AcquisitionIngress.open(c,fresh,"audio",spec.descriptor_ref)
    assert recovered.durable_sample == 2 and recovered.durable_sequence == 1
    assert handoff["imported"]["durable_sample"] == "2"
    assert {:ok,%{receipt: same}}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame()})
    assert Receipt.exact_prefix?(same,recovered)
    assert {:ok,%{terminal: true}}=AcquisitionIngress.call(owner,{:finish,"1","2",nil})
  end

  @tag :tmp_dir
  test "live expiry retires volatile tail and seals only verified committed prefix under settlement",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,_,_}=IntegrationFixtures.browser(c)
    {:ok,owner,_}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
    {:ok,_}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame()})
    {:ok,_}=AcquisitionIngress.call(owner,:checkpoint)
    {:ok,volatile}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame(1,2)})
    refute Receipt.durable?(volatile.receipt)
    assert {:ok,:ok}=Encounters.close(c.db,"encounter","clinician")
    start_supervised!({AcquisitionExpiry,c})
    wait_promoted(c,bind.id)
    [["promoted",manifest]]=AcquisitionSessions.rows(c.db,"SELECT a.state,m.body FROM acquisitions a JOIN acquisition_manifests m ON m.acquisition_id=a.id WHERE a.id=$1",[bind.id])
    assert manifest["streams"]["audio"]["index"]["next_sample"] == "2"
    assert manifest["streams"]["audio"]["index"]["terminal"] == "interrupted"
    refute manifest["streams"]["audio"]["index"]["fence"] == volatile.receipt.fence
    assert [["quiescent"],["terminal"]]=AcquisitionSessions.rows(c.db,"SELECT attempt_state FROM stream_attempts WHERE acquisition_id=$1 ORDER BY generation",[bind.id])
    assert Enum.any?(manifest["defects"],&(&1["code"] == "interrupted"))
    assert Enum.any?(manifest["facts"],&(&1["body"]["trailing_loss"] == "unknown"))
    assert {:error,_}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
  end

  @tag :tmp_dir
  test "same-generation retired journal is never reopened writable and fresh admission imports it",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,hello,principal}=IntegrationFixtures.browser(c)
    {:ok,owner,%{receipt: old}}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
    assert :ok=AcquisitionIngress.call(owner,:retire)
    assert {:error,:readmission_required}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
    {:ok,fresh}=AcquisitionSessions.admit(c.db,principal,hello)
    assert {:ok,owner,%{receipt: new,handoff: assertion}}=AcquisitionIngress.open(c,fresh,"audio",spec.descriptor_ref)
    refute old.fence == new.fence
    assert assertion["previous"] == Receipt.to_map(old)
    assert new.durable_sequence == 0 and new.durable_sample == 0
    assert {:ok,%{terminal: true}}=AcquisitionIngress.call(owner,{:finish,"0","0",nil})
  end

  @tag :tmp_dir
  test "live expiry records an actual empty interrupted journal for an admitted source with no received frames",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,_,_,_}=IntegrationFixtures.browser(c)
    {:ok,:ok}=Encounters.close(c.db,"encounter","clinician")
    start_supervised!({AcquisitionExpiry,c})
    wait_promoted(c,bind.id)
    [[manifest]]=AcquisitionSessions.rows(c.db,"SELECT body FROM acquisition_manifests WHERE acquisition_id=$1",[bind.id])
    index=manifest["streams"]["audio"]["index"]
    assert index["next_sequence"] == "0" and index["next_sample"] == "0"
    assert index["terminal"] == "interrupted" and index["segments"] == []
    assert {:ok,_}=AcquisitionManifest.verify_review(c,"encounter",bind.id,"clinician",MedEx.Serialization.digest(manifest))
  end

  @tag :tmp_dir
  test "loss of SQL exclusion before journal work permits rotation but neither successor effects nor promotion",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,hello,principal}=IntegrationFixtures.browser(c)
    barriers=Path.join(root,"barriers")
    File.mkdir_p!(barriers)
    Application.put_env(:mf_exam,:barriers,barriers)
    on_exit(fn->Application.delete_env(:mf_exam,:barriers) end)
    parent=self()
    source=Task.async(fn->
      {:ok,owner,_}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
      {:ok,_}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame()})
      send(parent,{:accepted,owner})
      receive do :checkpoint->AcquisitionIngress.call(owner,:checkpoint) end
    end)
    assert_receive {:accepted,old_owner},10_000
    File.write!(Path.join(barriers,"writer_stall.audio.armed"),"")
    send(source.pid,:checkpoint)
    backend=Path.join(barriers,"writer_stall.audio.reached") |> IntegrationFixtures.wait_file() |> String.to_integer()
    assert [[true]]=AcquisitionSessions.rows(c.db,"SELECT pg_terminate_backend($1)",[backend])
    assert {:ok,fresh}=AcquisitionSessions.admit(c.db,principal,hello)
    assert fresh.generation>bind.generation
    assert Process.alive?(old_owner)
    assert {:error,:effect_in_flight}=MedFabric.Exam.DeviceRootLock.gate(c.root_owner,{bind.id,"audio"})
    successor=Task.async(fn->AcquisitionIngress.open(c,fresh,"audio",spec.descriptor_ref) end)
    assert Task.yield(successor,100) == nil
    assert [[0]]=AcquisitionSessions.rows(c.db,"SELECT count(*) FROM acquisition_manifests",[])
    assert [[1]]=AcquisitionSessions.rows(c.db,"SELECT count(*) FROM stream_attempts",[])
    File.rm!(Path.join(barriers,"writer_stall.audio.reached"))
    assert {:error,:outcome_unknown}=Task.await(source,40_000)
    assert {:error,_}=Task.await(successor,40_000)
    assert {:ok,owner,%{receipt: receipt}}=AcquisitionIngress.open(c,fresh,"audio",spec.descriptor_ref)
    assert receipt.durable_sample == 2
    assert {:ok,%{terminal: true}}=AcquisitionIngress.call(owner,{:finish,"1","2",nil})
    assert {:ok,_}=AcquisitionManifest.finish(c,fresh,%{})
    refute AcquisitionSessions.current?(c.db,bind)
  end

  defp wait_promoted(c,id,deadline \\ nil) do
    deadline=deadline || System.monotonic_time(:millisecond)+10_000
    case AcquisitionSessions.rows(c.db,"SELECT state FROM acquisitions WHERE id=$1",[id]) do
      [["promoted"]]->:ok
      _->
        assert System.monotonic_time(:millisecond)<deadline,"live expiry worker did not settle and promote"
        Process.sleep(20)
        wait_promoted(c,id,deadline)
    end
  end

end
