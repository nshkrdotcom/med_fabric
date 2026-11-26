defmodule MedFabric.Exam.PreviewIsolationTest do
  use ExUnit.Case, async: false

  alias MedEx.{SampleFrame, Serialization, StreamSpec, StreamWriter}
  alias MedFabric.Exam.{DeviceRootLock, PreviewGateway}
  alias MedFabric.Store.Postgres

  setup %{tmp_dir: dir} do
    old = for key <- [:lab, :sidecar], do: {key, Application.fetch_env(:mf_exam, key)}
    :ok = Application.stop(:mf_exam)

    Application.put_env(:mf_exam, :lab, %{
      device_enabled: true,
      artifact_dir: dir,
      encounters: %{},
      database_url: System.fetch_env!("DATABASE_URL")
    })

    on_exit(fn ->
      Application.stop(:mf_exam)

      for {key, value} <- old do
        case value do
          {:ok, value} -> Application.put_env(:mf_exam, key, value)
          :error -> Application.delete_env(:mf_exam, key)
        end
      end

      :ok = Application.start(:mf_exam)
      File.rm_rf!(dir)
    end)

    :ok
  end

  @tag :tmp_dir
  test "the preview relay can restart while a stream keeps writing", %{tmp_dir: dir} do
    Application.put_env(:mf_exam, :sidecar, %{url: "http://127.0.0.1:1", secret: "fixture"})
    :ok = Application.start(:mf_exam)

    root = Process.whereis(MedFabric.Exam.Supervisor)
    captures = Process.whereis(MedFabric.Exam.Captures)
    endpoint = Process.whereis(MedFabric.ExamWeb.Endpoint)
    pool = Process.whereis(Postgres)
    gateway = Process.whereis(PreviewGateway)
    ecg = :ets.whereis(:mf_live_ecg)

    spec = stream_spec()

    {:ok, writer} =
      DynamicSupervisor.start_child(captures, {
        StreamWriter,
        owner: self(), stream: spec, fence: "fixture", artifact_dir: Path.join(dir, "stream")
      })

    assert %{durable_sample: 1} = write_sample(writer, spec, 0)

    gateway_ref = Process.monitor(gateway)
    assert 1 = :erlang.trace(root, true, [:procs])
    Process.exit(gateway, :kill)
    assert_receive {:DOWN, ^gateway_ref, :process, ^gateway, :killed}
    assert_receive {:trace, ^root, :link, _}, 5_000
    Supervisor.which_children(root)

    assert restarted = Process.whereis(PreviewGateway)
    refute gateway == restarted
    assert captures == Process.whereis(MedFabric.Exam.Captures)
    assert endpoint == Process.whereis(MedFabric.ExamWeb.Endpoint)
    assert pool == Process.whereis(Postgres)
    assert ecg == :ets.whereis(:mf_live_ecg)
    assert %{durable_sequence: 2, durable_sample: 2} = write_sample(writer, spec, 1)

    {DeviceRootLock, guard, :worker, _} =
      Enum.find(Supervisor.which_children(root), &(elem(&1, 0) == DeviceRootLock))

    writer_ref = Process.monitor(writer)
    Process.exit(guard, :kill)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :shutdown}, 5_000

    assert {DeviceRootLock, replacement, :worker, _} =
             Enum.find(Supervisor.which_children(root), &(elem(&1, 0) == DeviceRootLock))

    refute guard == replacement
    refute captures == Process.whereis(MedFabric.Exam.Captures)
  end

  @tag :tmp_dir
  test "headless Exam keeps live ECG without running the sidecar relay" do
    Application.delete_env(:mf_exam, :sidecar)
    :ok = Application.start(:mf_exam)

    refute Process.whereis(PreviewGateway)
    assert :undefined == :ets.whereis(PreviewGateway)
    assert :ets.whereis(:mf_live_ecg) != :undefined
    assert :ok = PreviewGateway.feed("dropped", <<1>>)
  end

  defp write_sample(writer, spec, n) do
    assert {:ok, _} =
             StreamWriter.push(writer, %SampleFrame{
               stream_id: "ecg",
               source_epoch: 0,
               descriptor_ref: spec.descriptor_ref,
               sequence: n,
               first_sample: n,
               sample_count: 1,
               config_epoch: 0,
               payload: <<n::little-16>>
             })

    assert {:ok, receipt} = StreamWriter.checkpoint(writer)
    receipt
  end

  defp stream_spec do
    spec = %StreamSpec{
      acquisition_id: "recording",
      source_ref: "credential:1",
      boot_id: "boot",
      stream_id: "ecg",
      source_epoch: 0,
      descriptor_ref: String.duplicate("a", 64),
      modality: "medex:ecg",
      encoding: :s16le,
      sample_rate: {250, 1},
      channels: [%{id: "II", label: "II", unit: "uV", calibration: :unknown}],
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 32,
        max_payload_bytes: 64,
        commands: [],
        replay: :durable_spool
      }
    }

    %{spec | descriptor_ref: Serialization.descriptor_ref(spec)}
  end
end
