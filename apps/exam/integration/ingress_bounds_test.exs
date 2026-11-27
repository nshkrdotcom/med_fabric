Code.require_file("support/fixtures.exs", __DIR__)

defmodule MedFabric.Exam.IngressBoundsTest do
  use ExUnit.Case, async: false
  alias MedEx.Wire.{Control, Credit}
  alias MedFabric.Exam.{AcquisitionIngress, AcquisitionManifest, IntegrationFixtures}
  alias MedFabric.ExamWeb.AcquisitionSocket
  alias MedFabric.Store.AcquisitionSessions, as: S
  @max 9_223_372_036_854_775_807
  setup context, do: IntegrationFixtures.trusted_tmp(context)

  test "direct ingress rejects overflow before writer admission and leaves durable evidence unchanged", %{
    tmp_dir: root
  } do
    c = IntegrationFixtures.context(root)
    {bind, spec, _, _} = IntegrationFixtures.browser(c)
    {:ok, ingress, %{receipt: initial}} = AcquisitionIngress.open(c, bind, "audio", spec.descriptor_ref)
    dir = AcquisitionManifest.attempt_dir(c, bind.id, "audio", initial.fence)
    before_files = files(dir)
    before_rows = rows(c)
    socket = socket(c, bind, ingress, initial)
    before_credit = Credit.stats(socket.ledger)
    barriers = Path.join(root, "barriers")
    File.mkdir!(barriers)
    Application.put_env(:mf_exam, :barriers, barriers)
    on_exit(fn -> Application.delete_env(:mf_exam, :barriers) end)
    File.write!(Path.join(barriers, "effect_admitted.audio.armed"), "")

    for {sequence, first} <- [{@max, 0}, {@max + 1, 0}, {0xFFFFFFFFFFFFFFFF, 0}, {0, @max - 1}] do
      raw = IntegrationFixtures.frame(sequence, first)
      assert {:stop, :normal, 1008, {:text, "acquisition_request_denied"}, ^socket} =
               AcquisitionSocket.handle_in({raw, [opcode: :binary]}, socket)

      assert {:error, :invalid_frame} =
               AcquisitionIngress.call(ingress, {:frame, raw})

      assert Process.alive?(ingress)
      assert Credit.stats(socket.ledger) == before_credit
      assert files(dir) == before_files
      assert rows(c) == before_rows
      refute File.exists?(Path.join(barriers, "effect_admitted.audio.reached"))
    end

    File.rm!(Path.join(barriers, "effect_admitted.audio.armed"))
    assert {:ok, _} = AcquisitionIngress.call(ingress, {:frame, IntegrationFixtures.frame()})
    assert {:ok, %{receipt: %{durable_sequence: 1, durable_sample: 2}}} =
             AcquisitionIngress.call(ingress, :checkpoint)
  end

  test "a 92-byte gap has one exact 96-byte operation identity and mismatches have no effect", %{
    tmp_dir: root
  } do
    c = IntegrationFixtures.context(root)
    {bind, spec, _, _} = IntegrationFixtures.browser(c)
    {:ok, ingress, %{receipt: initial}} = AcquisitionIngress.open(c, bind, "audio", spec.descriptor_ref)
    socket = socket(c, bind, ingress, initial)
    dir = AcquisitionManifest.attempt_dir(c, bind.id, "audio", initial.fence)
    before_files = files(dir)
    before_rows = rows(c)
    id = String.duplicate("a", 92)
    operation_id = "gap-" <> id

    fields = %{
      "binding" => socket.binding,
      "operation_id" => "mismatched",
      "id" => id,
      "first" => "0",
      "end" => "2",
      "first_sequence" => "0",
      "next_sequence" => "1",
      "irreversible" => true,
      "cause" => "source_loss"
    }

    assert {:ok, raw} = Control.encode("gap", fields)
    assert {:stop, :normal, 1008, {:text, "acquisition_request_denied"}, refused} =
             AcquisitionSocket.handle_in({raw, [opcode: :text]}, socket)
    assert refused.ledger == socket.ledger
    assert files(dir) == before_files
    assert rows(c) == before_rows

    assert {:ok, raw} = Control.encode("gap", %{fields | "operation_id" => operation_id})
    assert {:push, {:text, reply}, accepted} =
             AcquisitionSocket.handle_in({raw, [opcode: :text]}, socket)
    assert {:ok, %{"operation_id" => ^operation_id, "receipt" => receipt}} =
             Control.decode(reply, ["durable"])
    assert receipt["durable_sequence"] == "1"
    assert receipt["durable_sample"] == "2"
    assert Credit.stats(accepted.ledger).outstanding_frames == 0
  end

  defp socket(context, bind, ingress, receipt) do
    binding = %{
      "acquisition" => bind.id,
      "profile" => bind.profile,
      "generation" => to_string(bind.generation),
      "connection" => bind.connection,
      "stream" => "audio",
      "fence" => receipt.fence,
      "journal_id" => receipt.journal_id
    }

    {:ok, ledger} = Credit.new(binding, 15, 262_144)

    %{
      context: context,
      bind: bind,
      binding: binding,
      writer: ingress,
      receipt: receipt,
      ledger: ledger,
      flush: nil,
      operation_id: "initial",
      max_frame_bytes: 0,
      max_payload_bytes: 0,
      max_pending_bytes: 0,
      max_pending_frames: 0
    }
  end

  defp files(dir) do
    for path <- Path.wildcard(Path.join(dir, "**/*")), File.regular?(path), into: %{} do
      {Path.relative_to(path, dir), File.read!(path)}
    end
  end

  defp rows(c) do
    {
      S.rows(c.db, "SELECT fence,receipt FROM stream_attempts ORDER BY fence", []),
      S.rows(c.db, "SELECT count(*) FROM transport_observations", [])
    }
  end
end
