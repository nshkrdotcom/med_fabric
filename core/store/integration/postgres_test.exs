defmodule MedFabric.Store.PostgresTest do
  use ExUnit.Case
  alias MedFabric.Store.Postgres

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    url = System.fetch_env!("DATABASE_URL")
    db = start_supervised!({Postgres, url: url, pool_size: 3})
    {:ok, :ok} = Postgres.migrate(db)
    key = {"pg-" <> Base.encode16(:crypto.strong_rand_bytes(8)), "recording"}
    pcm = <<123::little-16>>

    wav =
      <<"RIFF", 38::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
        1000::little-32, 2000::little-32, 2::little-16, 16::little-16, "data", 2::little-32,
        pcm::binary>>

    digest = fn bytes -> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) end

    a = %{
      acquisition_id: "recording",
      interval_ms: {0, 1},
      artifact_sha256: digest.(pcm),
      file_sha256: digest.(wav),
      continuity: :observed_continuous,
      sample_count: 1,
      sample_rate_hz: 1000
    }

    path = Path.join(dir, a.file_sha256 <> ".wav")
    File.write!(path, wav)
    assert :ok = Postgres.ready(db, key, "session", a, "source")
    %{db: db, key: key, a: a, path: path, url: url}
  end

  test "metadata conflict with identical PCM survives redelivery and blocks acceptance", c do
    assert :ok = Postgres.ready(c.db, c.key, "session", c.a, "source")

    assert {:error, :conflicting_recording} =
             Postgres.ready(c.db, c.key, "session", %{c.a | continuity: :unknown}, "source")

    assert {:error, :conflicting_recording} =
             Postgres.accept(c.db, c.key, c.tmp_dir, c.a.file_sha256, "actor")
  end

  test "changed artifact blocks acceptance and outbox creation", c do
    File.write!(c.path, "changed")

    assert {:error, :recording_changed} =
             Postgres.accept(c.db, c.key, c.tmp_dir, c.a.file_sha256, "actor")

    assert {:ok, %{accepted_by: nil}} = Postgres.fetch(c.db, c.key)

    assert {:error, :delivery_state_changed} =
             Postgres.delivery_result(c.db, c.key, {:ok, %{remote_ref: "Observation/1"}})
  end

  test "concurrent acceptance and manual retry preserve one decision and remote identity", c do
    results =
      for actor <- ["one", "two"] do
        Task.async(fn -> Postgres.accept(c.db, c.key, c.tmp_dir, c.a.file_sha256, actor) end)
      end

    assert [{:ok, :ok}, {:ok, :ok}] = Task.await_many(results)
    assert {:error, :timeout} = Postgres.delivery_result(c.db, c.key, {:error, :timeout})
    assert :ok = Postgres.delivery_result(c.db, c.key, {:ok, %{remote_ref: "Observation/1"}})

    assert {:error, :delivery_state_changed} =
             Postgres.delivery_result(c.db, c.key, {:ok, %{remote_ref: "Observation/2"}})

    stop_supervised!(Postgres)
    db = start_supervised!({Postgres, url: c.url})

    assert {:ok, %{accepted_by: actor, remote_ref: "Observation/1", last_error: nil}} =
             Postgres.fetch(db, c.key)

    assert actor in ["one", "two"]
  end
end
