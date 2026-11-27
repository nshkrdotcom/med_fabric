alias MedEx.{SampleFrame, Serialization, StreamSpec, StreamWriter}
alias MedEx.Storage.File, as: Storage
alias MedFabric.Exam.DeviceRootLock

[mode, root] = System.argv()
Process.flag(:trap_exit, true)

children = [
  {DeviceRootLock,
   [name: DeviceRootLock, root: root, deployment_uuid: "00000000-0000-4000-8000-000000000002"]},
  {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Exam.Captures}
]

case Supervisor.start_link(children, strategy: :rest_for_one) do
  {:error, {:shutdown, {:failed_to_start_child, DeviceRootLock, :artifact_root_in_use}}} ->
    IO.puts("refused")
    System.halt(78)

  {:ok, supervisor} ->
    {DeviceRootLock, guard, :worker, _} =
      List.keyfind(Supervisor.which_children(supervisor), DeviceRootLock, 0)

    {:os_pid, helper_pid} = guard |> :sys.get_state() |> Map.fetch!(:port) |> Port.info(:os_pid)

    descriptor = %StreamSpec{
      descriptor_ref: "",
      acquisition_id: "exam-root-lock",
      source_ref: "synthetic",
      stream_id: "ecg",
      source_epoch: 0,
      boot_id: "boot",
      modality: "medex:ecg",
      encoding: :s16le,
      sample_rate: {250, 1},
      channels: [%{id: "lead", label: "I", unit: "uV", calibration: :unknown}],
      capabilities: %{
        encodings: [:s16le],
        max_frame_samples: 2,
        max_payload_bytes: 4,
        replay: :durable_spool,
        commands: []
      }
    }

    descriptor = %{descriptor | descriptor_ref: Serialization.descriptor_ref(descriptor)}
    attempt = Path.join(root, "attempt")
    fence = "first-fence"
    payload = <<1, 0, 2, 0>>

    case mode do
      "write" ->
        {:ok, writer} =
          DynamicSupervisor.start_child(
            MedFabric.Exam.Captures,
            {StreamWriter,
             owner: self(),
             stream: descriptor,
             artifact_dir: attempt,
             fence: fence,
             root_owner: guard,
             limits: %{checkpoint_ms: :manual}}
          )

        frame = %SampleFrame{
          stream_id: descriptor.stream_id,
          source_epoch: 0,
          descriptor_ref: descriptor.descriptor_ref,
          sequence: 0,
          first_sample: 0,
          sample_count: 2,
          config_epoch: 0,
          payload: payload
        }

        {:ok, _} = StreamWriter.push(writer, fence, frame, 5_000)

        {:ok, %{durable_sequence: 1, durable_sample: 2}} =
          StreamWriter.checkpoint(writer, fence, 5_000)

        true = Process.alive?(writer)

      "recover" ->
        {:ok, %{receipt: %{durable_sequence: 1, durable_sample: 2}, index: %{segments: [chunk]}}} =
          Storage.recover(attempt, stream: descriptor, fence: fence, root_owner: guard)

        {:ok, ^payload} = File.read(Path.join(attempt, chunk.key))
    end

    IO.puts("ready #{System.pid()} #{helper_pid}")
    IO.read(:line)
end
