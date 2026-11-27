Code.require_file("support/fixtures.exs",__DIR__)
defmodule MedFabric.Exam.NativeScopeTest do
  use ExUnit.Case,async: false
  alias MedFabric.Exam.IntegrationFixtures,as: F
  alias MedFabric.Store.{Records,Encounters,Deliveries,AcquisitionSessions}
  @tag :tmp_dir
  test "native manual acceptance is atomic, replayable after closure, and independent of destination",%{tmp_dir: root} do
    c=F.context(root)
    {:ok,evidence}=MedFabric.Domain.Evidence.pulse_rate(76,~U[2026-11-24 12:00:00Z],"clinician")
    assert {:ok,"manual_one"}=Records.put_manual(c.db,"encounter","manual_one","clinician",evidence)
    assert {:error,:unauthorized}=Records.put_manual(c.db,"encounter","manual_two","patient",evidence)
    {:ok,source}=Records.manual(c.db,"encounter","manual_one","clinician")
    {:ok,plan}=MedFabric.Domain.Review.plan(source,"clinician","review_one",%{"decision"=>"accept"},~U[2026-11-24 12:01:00Z])
    tasks=for _<-1..2,do: Task.async(fn->Records.accept_plan(c.db,plan) end)
    [first,second]=Enum.map(tasks,&Task.await(&1,10_000))
    assert first == second
    assert {:ok,%{observations: [id]}}=first
    assert {:ok,%{status: "pending",destination: nil,resource: nil,identifier_value: ^id}}=Deliveries.get(c.db,id)
    assert [[1]]=AcquisitionSessions.rows(c.db,"SELECT count(*) FROM reviews",[])
    assert [[1]]=AcquisitionSessions.rows(c.db,"SELECT count(*) FROM observations",[])
    assert {:ok,"blocked"}=MedFabric.Exam.DeliveryWorker.run(c,id) |> normalize_blocked(c,id)
    assert {:ok,:ok}=Encounters.close(c.db,"encounter","clinician")
    assert ^first=Records.accept_plan(c.db,plan)
    {:ok,other}=MedFabric.Domain.Review.plan(source,"clinician","new_request",%{"decision"=>"accept"},DateTime.utc_now())
    assert {:error,:unauthorized}=Records.accept_plan(c.db,other)
    assert {:ok,%{status: "blocked"}}=Deliveries.get(c.db,id)
  end
  defp normalize_blocked(_,c,id) do
    {:ok,intent}=Deliveries.get(c.db,id)
    {:ok,intent.status}
  end

  @tag :tmp_dir
  test "manual evidence id cannot be reused across encounters even for identical body",%{tmp_dir: root} do
    c=F.context(root)
    {:ok,:ok}=Encounters.open(c.db,%{"exam"=>"other","patient_actor"=>"other-patient","clinician_actor"=>"clinician"})
    {:ok,evidence}=MedFabric.Domain.Evidence.pulse_rate(0,DateTime.utc_now(),"clinician")
    assert {:ok,_}=Records.put_manual(c.db,"encounter","same_id","clinician",evidence)
    assert {:error,:manual_evidence_conflict}=Records.put_manual(c.db,"other","same_id","clinician",evidence)
    assert {:error,:unknown_evidence}=Records.manual(c.db,"other","same_id","clinician")
  end
end
