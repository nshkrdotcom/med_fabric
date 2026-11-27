# Actual TLS/WS denial lane in the disposable second encounter.
alias MedEx.Serialization
alias MedEx.Wire.FrameV1
alias MedExHandheld.{Paired, Transport}
[cfgpath] = Enum.reject(System.argv(), &(&1 == "--"))
config = cfgpath |> File.read!() |> JSON.decode!()
epoch = 2
sources = Paired.sources(Map.put(config, "boot", "denial-fixture"))

descriptors =
  Map.new(sources, fn {name, {_, spec}} ->
    spec = %{spec | source_epoch: epoch}
    {name, Serialization.to_map(%{spec | descriptor_ref: Serialization.descriptor_ref(spec)})}
  end)

hello = %{
  "api_revision" => 2,
  "acquisition" => config["acquisition"],
  "encounter" => config["encounter"],
  "profile" => "paired_exam",
  "boot" => "denial-fixture",
  "descriptors" => descriptors,
  "max_credit_frames" => 15,
  "max_credit_bytes" => 262_144
}

denied = fn response ->
  case response do
    {:error, _} -> :ok
    {:ok, %{"type" => "refused"}} -> :ok
    _ -> raise "unauthorized effect was admitted"
  end
end

{:ok, wrong} = Transport.connect(config, "control")
denied.(Transport.request(wrong, "hello", %{hello | "encounter" => config["wrong_encounter"]}))
Transport.close(wrong)
{:ok, invalid} = Transport.connect(config, "control")

:ok =
  Transport.send_frame(
    invalid,
    {:text, ~s({"schema":"medex.acquisition.v2","type":"hello","type":"heartbeat"})}
  )

denied.(Transport.recv(invalid))
Transport.close(invalid)
{:ok, control} = Transport.connect(config, "control")
{:ok, %{"type" => "admitted"} = old} = Transport.request(control, "hello", hello)

fields = fn admission ->
  %{
    "binding" => admission["binding"],
    "lease" => admission["lease"],
    "acquisition" => admission["binding"]["acquisition"],
    "generation" => admission["binding"]["generation"],
    "stream" => "audio",
    "descriptor_ref" => descriptors["audio"]["descriptor_ref"],
    "max_credit_frames" => 15,
    "max_credit_bytes" => 262_144
  }
end

open = fn fields ->
  {:ok, socket} = Transport.connect(config, "stream")
  {Transport.request(socket, "open_stream", fields), socket}
end

{result, bad} = open.(Map.put(fields.(old), "descriptor_ref", String.duplicate("0", 64)))
denied.(result)
Transport.close(bad)
{{:ok, %{"type" => "durable"}}, stream} = open.(fields.(old))
{result, duplicate} = open.(fields.(old))
denied.(result)
Transport.close(duplicate)
{:ok, replacement} = Transport.connect(config, "control")
{:ok, %{"type" => "admitted"} = new} = Transport.request(replacement, "hello", hello)
true = old["binding"]["generation"] != new["binding"]["generation"]

frame = %FrameV1{
  stream_number: 1,
  source_epoch: epoch,
  config_epoch: 0,
  sequence: 0,
  first_sample: 0,
  sample_count: 1,
  payload: <<5::little-16>>
}

{:ok, raw} = FrameV1.encode(frame)
:ok = Transport.send_frame(stream, {:binary, raw})
denied.(Transport.recv(stream))
Transport.close(stream)
Transport.close(control)

Transport.close(replacement)

readmit = fn ->
  {:ok, control} = Transport.connect(config, "control")
  {:ok, %{"type" => "admitted"} = admission} = Transport.request(control, "hello", hello)
  {control, admission}
end

for changed <- [%{frame | stream_number: 2}, %{frame | source_epoch: 0}] do
  {active_control, admission} = readmit.()
  {{:ok, %{"type" => "durable"}}, invalid} = open.(fields.(admission))
  {:ok, bytes} = FrameV1.encode(changed)
  :ok = Transport.send_frame(invalid, {:binary, bytes})
  denied.(Transport.recv(invalid))
  Transport.close(invalid)
  Transport.close(active_control)
end

{final_control, final_admission} = readmit.()
{{:ok, %{"type" => "durable", "binding" => binding}}, stream} = open.(fields.(final_admission))
:ok = Transport.send_frame(stream, {:binary, raw})
{:ok, %{"type" => "accepted", "binding" => ^binding}} = Transport.recv(stream)

{:ok,
 %{
   "type" => "durable",
   "binding" => ^binding,
   "receipt" => %{"durable_sample" => "1", "source_epoch" => "2"}
 }} = Transport.recv(stream)

{:ok, changed} = FrameV1.encode(%{frame | payload: <<6::little-16>>})
:ok = Transport.send_frame(stream, {:binary, changed})
denied.(Transport.recv(stream))
Transport.close(stream)
Transport.close(final_control)

File.write!(
  config["negative_result"],
  JSON.encode!(%{
    "checked" =>
      ~w(wrong_encounter duplicate_json descriptor_mismatch competing_producer stale_generation swapped_number mismatched_epoch nonzero_epoch conflicting_replay)
  })
)
