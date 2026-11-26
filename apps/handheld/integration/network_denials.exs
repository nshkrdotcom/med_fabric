# Run by the OS harness against a second synthetic encounter over authenticated TLS.
alias MedExHandheld.{Transport, Paired}
alias MedEx.{Serialization, Wire.FrameV1}
[cfgpath] = System.argv() |> Enum.reject(&(&1 == "--"))
c = File.read!(cfgpath) |> JSON.decode!()
sources = Paired.sources(c)
epoch = 2

descriptors =
  Map.new(sources, fn {name, {_, spec}} ->
    spec = %{spec | source_epoch: epoch}
    {name, Serialization.to_map(%{spec | descriptor_ref: Serialization.descriptor_ref(spec)})}
  end)

hello = %{
  "acquisition" => c["acquisition"],
  "encounter" => c["encounter"],
  "profile" => "paired_exam",
  "boot" => "denial-fixture",
  "descriptors" => descriptors
}

denied = fn response ->
  case response do
    {:error, _} -> :ok
    _ -> raise "invalid fixture input unexpectedly admitted"
  end
end

{:ok, wrong} = Transport.connect(c, "control")
denied.(Transport.request(wrong, "hello", %{hello | "encounter" => c["wrong_encounter"]}))
Transport.close(wrong)
{:ok, invalid} = Transport.connect(c, "control")

:ok =
  Transport.send_frame(
    invalid,
    {:text, ~s({"schema":"medex.device.v1","type":"hello","type":"heartbeat"})}
  )

denied.(Transport.recv(invalid))
Transport.close(invalid)
{:ok, ctl} = Transport.connect(c, "control")
{:ok, %{"type" => "admitted"} = old} = Transport.request(ctl, "hello", hello)

binding = fn msg ->
  Map.take(msg, ~w(acquisition lease generation))
  |> Map.merge(%{"stream" => "audio", "descriptor_ref" => descriptors["audio"]["descriptor_ref"]})
end

open = fn message ->
  {:ok, ws} = Transport.connect(c, "stream")
  {Transport.request(ws, "open_stream", message), ws}
end

{r, bad} = open.(Map.put(binding.(old), "descriptor_ref", String.duplicate("0", 64)))
denied.(r)
Transport.close(bad)
{{:ok, %{"type" => "durable"}}, stream} = open.(binding.(old))
{r, duplicate} = open.(binding.(old))
denied.(r)
Transport.close(duplicate)
{:ok, newctl} = Transport.connect(c, "control")
{:ok, %{"type" => "admitted"} = new} = Transport.request(newctl, "hello", hello)
true = old["generation"] != new["generation"]

f = %FrameV1{
  stream_number: 1,
  source_epoch: epoch,
  config_epoch: 0,
  sequence: 0,
  first_sample: 0,
  sample_count: 1,
  payload: <<5::little-16>>
}

{:ok, raw} = FrameV1.encode(f)
:ok = Transport.send_frame(stream, {:binary, raw})
denied.(Transport.recv(stream))
Transport.close(stream)
Transport.close(ctl)
{{:ok, %{"type" => "durable"}}, stream} = open.(binding.(new))
{:ok, badframe} = FrameV1.encode(%{f | stream_number: 2})
:ok = Transport.send_frame(stream, {:binary, badframe})
denied.(Transport.recv(stream))
Transport.close(stream)
{{:ok, %{"type" => "durable"}}, stream} = open.(binding.(new))
{:ok, bad_epoch} = FrameV1.encode(%{f | source_epoch: 0})
:ok = Transport.send_frame(stream, {:binary, bad_epoch})
denied.(Transport.recv(stream))
Transport.close(stream)
{{:ok, %{"type" => "durable"}}, stream} = open.(binding.(new))
:ok = Transport.send_frame(stream, {:binary, raw})
{:ok, %{"type" => "accepted"}} = Transport.recv(stream)

{:ok, %{"type" => "durable", "durable_sample" => "1", "source_epoch" => "2"}} =
  Transport.recv(stream)

{:ok, changed} = FrameV1.encode(%{f | payload: <<6::little-16>>})
:ok = Transport.send_frame(stream, {:binary, changed})
denied.(Transport.recv(stream))
Transport.close(stream)
Transport.close(newctl)

File.write!(
  c["negative_result"],
  JSON.encode!(%{
    "checked" =>
      ~w(wrong_encounter duplicate_json descriptor_mismatch competing_producer stale_generation swapped_number mismatched_epoch nonzero_epoch conflicting_replay)
  })
)
