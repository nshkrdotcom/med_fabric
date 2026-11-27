Code.require_file("support/fixtures.exs",__DIR__)
defmodule MedFabric.Exam.PreviewIsolationTest do
  use ExUnit.Case,async: false
  alias MedFabric.Exam.{IntegrationFixtures,PreviewGateway,AcquisitionIngress}
  alias MedFabric.Store.{Encounters,AcquisitionSessions}
  @tag :tmp_dir
  test "absent and restarted disposable preview cannot stop the common authoritative writer",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,_,_}=IntegrationFixtures.browser(c)
    assert :ok=PreviewGateway.feed(bind,spec,IntegrationFixtures.frame())
    {:ok,owner,_}=AcquisitionIngress.open(c,bind,"audio",spec.descriptor_ref)
    {:ok,_}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame()})
    assert {:ok,%{receipt: %{durable_sample: 2}}}=AcquisitionIngress.call(owner,:checkpoint)
    gateway=start_supervised!({PreviewGateway,%{url: "http://127.0.0.1:1",secret: String.duplicate("s",32)}})
    ref=Process.monitor(gateway)
    Process.exit(gateway,:kill)
    assert_receive {:DOWN,^ref,:process,^gateway,:killed}
    assert Process.alive?(owner)
    {:ok,_}=AcquisitionIngress.call(owner,{:frame,IntegrationFixtures.frame(1,2)})
    assert {:ok,%{receipt: %{durable_sample: 4}}}=AcquisitionIngress.call(owner,:checkpoint)
  end
  @tag :tmp_dir
  test "latest monitor slots stay finite under concurrent producers and failed sidecar requests",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,spec,_,_}=IntegrationFixtures.browser(c)
    start_supervised!({PreviewGateway,%{url: "http://127.0.0.1:1",secret: String.duplicate("s",32)}})
    1..256 |> Enum.map(fn n->Task.async(fn->PreviewGateway.feed(%{bind|id: "feed_#{n}"},spec,IntegrationFixtures.frame()) end) end) |> Enum.each(&Task.await/1)
    assert :ets.info(PreviewGateway,:size)<=64
  end
  @tag :tmp_dir
  test "viewing capability lifetime is capped by both source and current viewer session",%{tmp_dir: root} do
    c=IntegrationFixtures.context(root)
    {bind,_,_,_}=IntegrationFixtures.browser(c)
    {:ok,:ok}=Encounters.browser_session(c.db,"viewer","encounter","clinician",:clinician)
    AcquisitionSessions.rows(c.db,"UPDATE browser_sessions SET expires_at=clock_timestamp()+interval '2 seconds' WHERE id='viewer'",[])
    assert {:ok,snapshot}=AcquisitionSessions.preview_authority(c.db,"encounter",bind.id,"clinician","viewer")
    assert snapshot.preview_remaining_ms in 1..2000
    [body,_signature]=String.split(PreviewGateway.capability(%{secret: String.duplicate("s",32)},snapshot,"clinician","viewer"),".")
    {:ok,bytes}=Base.url_decode64(body,padding: false)
    {:ok,claims}=MedEx.CanonicalJSON.decode(bytes)
    assert String.to_integer(claims["expires_at_ms"])-String.to_integer(claims["issued_at_ms"]) == snapshot.preview_remaining_ms
    assert claims["viewer_session"] == "viewer" and claims["descriptor_ref"] == snapshot.descriptors["audio"]["descriptor_ref"]
    AcquisitionSessions.rows(c.db,"UPDATE acquisition_sessions SET expires_at=clock_timestamp()+interval '1 second' WHERE id=$1",[bind.id])
    assert {:ok,shorter}=AcquisitionSessions.preview_authority(c.db,"encounter",bind.id,"clinician","viewer")
    assert shorter.preview_remaining_ms in 1..1000
    AcquisitionSessions.rows(c.db,"UPDATE browser_sessions SET revoked=true WHERE id='viewer'",[])
    assert {:error,:session_expired}=AcquisitionSessions.preview_authority(c.db,"encounter",bind.id,"clinician","viewer")
  end
end
