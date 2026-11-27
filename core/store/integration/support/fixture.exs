defmodule MedFabric.Store.IntegrationFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Bitwise
  alias MedFabric.Domain.Evidence
  alias MedFabric.Store.{AcquisitionSessions, DeviceSessions, Encounters, Postgres, Records}

  # Selected integration tests require real PostgreSQL and fail when absent.
  # Each fixture owns one unpredictable search_path schema; it never alters
  # public, uses a global named pool, or starts an Exam host.
  def database do
    url = System.fetch_env!("DATABASE_URL")
    schema = "store_test_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)
    uuid = "00000000-0000-4000-8000-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    admin = start_supervised!(Supervisor.child_spec({Postgres, url: url, pool_size: 1}, id: {:admin, schema}))
    Postgrex.query!(admin, "CREATE SCHEMA " <> schema, [])
    on_exit(fn ->
      {:ok, cleanup} = Postgres.start_link(url: url, pool_size: 1)
      try do Postgrex.query!(cleanup, "DROP SCHEMA " <> schema <> " CASCADE", []) after GenServer.stop(cleanup) end
    end)
    db = start_supervised!(Supervisor.child_spec({Postgres, url: url, parameters: [search_path: schema], pool_size: 8}, id: {:database, schema}))
    assert {:ok, :ok} = Postgres.migrate(db, uuid)
    %{db: db, schema: schema, uuid: uuid}
  end

  def encounter(db, id \\ "encounter") do
    assert {:ok, :ok} = Encounters.open(db, %{"exam" => id, "patient_actor" => "patient", "clinician_actor" => "clinician"})
    :ok
  end

  def manual(db, id \\ "manual", value \\ 70) do
    {:ok, body} = Evidence.pulse_rate(value, ~U[2026-11-24 12:00:00Z], "clinician")
    assert {:ok, ^id} = Records.put_manual(db, "encounter", id, "clinician", body)
    assert {:ok, source} = Records.manual(db, "encounter", id, "clinician")
    source
  end

  def device(db) do
    token = String.duplicate("t", 48)
    assert DeviceSessions.enroll(db, "gateway", token)
    for profile <- ["paired_exam", "plx_spot_check"] do
      assert {:ok, :ok} = DeviceSessions.authorize(db, "encounter", "gateway", profile, "Synthetic anterior site", "clinician")
    end
    %{kind: :device, id: "gateway"}
  end

  def hello(profile \\ "paired_exam", id \\ "acquisition", boot \\ "boot", source \\ "gateway") do
    names = case profile do "paired_exam" -> ["audio", "ecg"]; "browser_microphone" -> ["audio"]; "plx_spot_check" -> [] end
    descriptors = Map.new(names, fn name -> {name, MedEx.Serialization.to_map(spec(name, id, source, boot, profile))} end)
    %{"api_revision" => 2, "acquisition" => id, "encounter" => "encounter", "boot" => boot, "profile" => profile, "descriptors" => descriptors}
  end

  def spec(name, id, source, boot, profile \\ "paired_exam") do
    modality = if profile == "browser_microphone", do: "medex:browser_microphone", else: if(name == "audio", do: "medex:diagnostic_audio", else: "medex:ecg")
    spec = %MedEx.StreamSpec{acquisition_id: id, source_ref: source, boot_id: boot, stream_id: name,
      source_epoch: 0, descriptor_ref: "", modality: modality, encoding: :s16le,
      sample_rate: {if(name == "audio", do: 48_000, else: 250), 1},
      channels: [%{id: name, label: name, unit: :unknown, calibration: :unknown}],
      capabilities: %{encodings: [:s16le], max_frame_samples: 960, max_payload_bytes: 1920,
        replay: if(profile == "browser_microphone", do: :none, else: :durable_spool), commands: []}}
    %{spec | descriptor_ref: MedEx.Serialization.descriptor_ref(spec)}
  end

  def applied(command, first_sample \\ "960") do
    command
    |> Map.take(~w(id fingerprint boot target generation gain expected_epoch))
    |> Map.merge(%{"status" => "applied", "epoch" => to_string(String.to_integer(command["expected_epoch"]) + 1),
      "application" => %{"observed_at" => "100", "first_sample" => first_sample}})
  end

  def event(acquisition, id \\ "event_one", sequence \\ 0, pulse \\ 721) do
    raw = <<7, 0xF3CC::little-16, (0xF000 ||| (pulse &&& 0xFFF))::little-16, 2020::little-16,
      1, 2, 3, 4, 5, 0x0500::little-16, 0::little-24>>
    at = ~U[2020-01-02 03:04:05Z]
    facts = [{"source", :observed, "synthetic-plx"}, {"simulated", :observed, true}, {"phase", :observed, "completed"},
      {"features_raw", :observed, Base.encode64(<<15::little-16, 0xFFFF::little-16, 0xFFFF::little-24>>)},
      {"decoder", :claimed, "plxs-1.0.1"}, {"time_basis", :claimed, "qualified_fixture_utc"},
      {"peripheral_redelivery", :observed, "ambiguous_without_record_id"}]
    %MedEx.MeasurementEvent{event_id: id, acquisition_id: acquisition, source_ref: "gateway", boot_id: "boot",
      stream_id: "plx", source_epoch: 0, gateway_sequence: sequence,
      descriptor_ref: MedFabric.Domain.DeviceMeasurement.descriptor_ref(),
      metrics: %{"spo2" => {:value, 972, -1, "%"}, "pulse_rate" => {:value, pulse, -1, "/min"}},
      raw: {:bytes, raw}, device_status: %{"measurement" => "1280", "device" => "0"},
      device_time: %{clock_id: "unix_us", boot_id: "fixture", ticks: DateTime.to_unix(at, :microsecond), uncertainty_ticks: 0},
      provenance: Enum.map(facts, fn {name, origin, value} -> %{name: name, origin: origin, value: value} end)}
    |> MedEx.Serialization.to_map()
  end

  def blocked_by?(db, backend, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3000
    case AcquisitionSessions.rows(db, "SELECT 1 FROM pg_stat_activity WHERE $1::integer=ANY(pg_blocking_pids(pid))", [backend]) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          blocked_by?(db, backend, deadline)
        else false end
      _ -> true
    end
  end
end
