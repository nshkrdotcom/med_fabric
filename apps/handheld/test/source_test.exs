defmodule MedExHandheld.SourceTest do
  use ExUnit.Case,async: true
  alias MedExHandheld.{ReferencePeripheral,RDP1,Spool,Monitor,PLXPeripheral}

  test "RDP1 independent CRC vector survives every split and coalesced reads" do
    bytes=File.read!(Path.join(__DIR__,"fixtures/rdp1_waveform.bin"))
    {:ok,"",[event]}=RDP1.decode("",bytes)
    assert event.sample_count>0
    for split<-0..byte_size(bytes) do
      <<left::binary-size(split),right::binary>>=bytes
      {:ok,buf,events}=RDP1.decode("",left)
      {:ok,"",rest}=RDP1.decode(buf,right<>bytes)
      assert events++rest==[event,event]
    end
    <<a::binary-size(35),n,rest::binary>>=bytes
    assert {:error,:bad_crc,_}=RDP1.decode("",a<><<Bitwise.bxor(n,1)>><>rest)
    assert {:error,:framing_limit,_}=RDP1.decode("",:binary.copy(<<0>>,4200))
  end

  test "raw control request replay cannot restart sampling and changed request conflicts" do
    p=ReferencePeripheral.new(1,71)
    body=%{"schema"=>"rdp1.control.v1","request_id"=>"start-1","op"=>"start","args"=>%{"acquisition"=>"test","profile"=>"reference"}}
    packet=fn m->RDP1.packet(16,1,71,0,0,0,0,JSON.encode!(m)) end
    {p,reply}=ReferencePeripheral.request(p,packet.(body))
    {p,raw}=ReferencePeripheral.emit(p,32,80,1)
    assert {^p,^reply}=ReferencePeripheral.request(p,packet.(body))
    {_,[conflict]}=ReferencePeripheral.request(p,packet.(%{body | "op"=>"stop"}))
    assert ReferencePeripheral.fragmented(conflict).body["error"]=="request_conflict"
    {_,_,[replayed]}=ReferencePeripheral.transact(p,"replay",%{"first"=>0,"next"=>1})
    assert replayed==raw
  end

  test "RACP count/report/abort/timeout retain device records" do
    p=PLXPeripheral.new()
    assert {^p,{:error,:cccd_improperly_configured}}=PLXPeripheral.racp(p,<<4,1>>)
    p=PLXPeripheral.subscribe(p)
    {^p,<<5,0,2::little-16>>}=PLXPeripheral.racp(p,<<4,1>>)
    {busy,{:indications,rows}}=PLXPeripheral.racp(p,<<1,1>>)
    assert {^busy,{:error,:procedure_in_progress}}=PLXPeripheral.racp(busy,<<1,1>>)
    assert {^p,<<6,0,3,1>>}=PLXPeripheral.racp(busy,<<3,0>>)
    assert {^p,:outcome_unknown}=PLXPeripheral.timeout(busy)
    assert rows==p.records
  end

  @tag :tmp_dir
  test "spool recovery keeps unacknowledged bytes and rejects predecessor ACK",%{tmp_dir: dir} do
    p=start_supervised!(Supervisor.child_spec({Spool,root: dir,limit: 100},id: :spool_before_restart,restart: :temporary))
    {:ok,raw}=MedEx.Wire.FrameV1.encode(%MedEx.Wire.FrameV1{stream_number: 1,source_epoch: 0,config_epoch: 0,
      sequence: 0,first_sample: 0,sample_count: 1,payload: <<1,2>>})
    assert :ok=Spool.put(p,"audio",0,raw)
    assert {:error,:spool_full}=Spool.put(p,"audio",1,:binary.copy(<<1>>,63))
    GenServer.stop(p)
    p=start_supervised!(Supervisor.child_spec({Spool,root: dir,limit: 100},id: :spool_after_restart,restart: :temporary))
    assert {:ok,^raw}=Spool.get(p,"audio",0)
    r=%{"fence"=>"second","stream_id"=>"audio","descriptor_ref"=>String.duplicate("a",64),"journal_id"=>"journal",
      "source_epoch"=>"0","journal_generation"=>"2","accepted_sequence"=>"1","accepted_sample"=>"1","durable_sample"=>"1",
      "durable_sequence"=>"1","journal_digest"=>String.duplicate("a",64)}
    Spool.write!(Path.join([dir,"audio","source.json"]),JSON.encode!(%{"sequence"=>1,"sample"=>1,"done"=>true}))
    spec=%{stream_id: "audio",source_epoch: 0,descriptor_ref: r["descriptor_ref"]}
    :ok=Spool.activate(p,"audio",2,spec,r)
    assert {:error,:stale_fence}=Spool.ack(p,"audio",1,r)
    assert :ok=Spool.ack(p,"audio",2,r)
    assert :absent=Spool.get(p,"audio",0)
  end

  @tag :tmp_dir
  test "monitor command replays exact result after restart, including persisted refusals",%{tmp_dir: dir} do
    c=%{"id"=>"one","fingerprint"=>"hash","boot"=>"boot","gain"=>"half","expected_epoch"=>"0"}
    p=start_supervised!(Supervisor.child_spec({Monitor,{dir,"boot"}},id: :monitor_before_restart,restart: :temporary))
    assert :pending=GenServer.call(p,{:command,c})
    assert %{"status"=>"pending"}=GenServer.call(p,{:state,c})
    assert {"1",<<-16384::little-signed-16,0::little-16>>}=GenServer.call(p,{:frame,960,<<-32768::little-signed-16,-1::little-signed-16>>})
    assert {:result,r}=GenServer.call(p,{:command,c})
    assert r["first_sample"]=="960"
    rejected=%{c | "id"=>"two","fingerprint"=>"refused"}
    assert {:result,%{"status"=>"rejected"}=refused}=GenServer.call(p,{:command,rejected})
    GenServer.stop(p)
    p=start_supervised!(Supervisor.child_spec({Monitor,{dir,"boot"}},id: :monitor_after_restart,restart: :temporary))
    assert {:result,^r}=GenServer.call(p,{:command,c})
    assert {:result,^refused}=GenServer.call(p,{:command,rejected})
    assert {:error,:conflict}=GenServer.call(p,{:command,%{c | "fingerprint"=>"changed"}})
  end
end
