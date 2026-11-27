# Run with plain Elixir: elixir config/runtime_test.exs
ExUnit.start()

defmodule MedFabric.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @root Path.expand("..", __DIR__)
  @env ~w(MF_LAB MF_PREVIEW_CONFIG MF_PREVIEW_PORT MF_PREVIEW_URL
          MF_PREVIEW_CREDENTIAL_FILE MF_ENCOUNTERS_FILE MF_HTTP_PORT MF_PUBLIC_ORIGIN
          MF_PROXY_SECRET MF_TURN_URLS MF_TURN_SECRET MF_RELAY_ONLY MF_DEVICE_TLS_CERTFILE
          MF_DEVICE_TLS_KEYFILE MF_DEVICE_BIND_IP MF_DEVICE_TLS_PORT MF_ARTIFACT_DIR
          MF_SECRET_KEY_BASE MF_DEPLOYMENT_UUID DATABASE_URL)

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), "mf-runtime-" <> suffix)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    credential = Path.join(dir, "preview.credential")
    File.write!(credential, "synthetic-preview-test-credential\n")
    System.put_env("MF_PREVIEW_CREDENTIAL_FILE", credential)
    System.put_env("MF_PREVIEW_PORT", "4090")
    config = Path.join(dir, "preview.json")

    File.write!(
      config,
      JSON.encode!(%{
        "port" => 4090,
        "credential_file" => credential,
        "trusted_clock" => true,
        "clock_error_ms" => 100
      })
    )

    System.put_env("MF_PREVIEW_CONFIG", config)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      File.rm_rf!(dir)
    end)

    %{credential: credential, root: dir}
  end

  test "Preview accepts its bounded loopback port and trims the credential" do
    config = read("preview")
    assert config[:mf_preview][:listen][:port] == 4090
    assert config[:mf_preview][:listen][:secret] == "synthetic-preview-test-credential"
    refute Keyword.has_key?(config, :med_ex)
  end

  test "Preview refuses empty credentials", %{credential: credential} do
    File.write!(credential, " \n\t")
    assert_raise RuntimeError, ~r/Unreadable Preview credential/, fn -> read("preview") end
  end

  test "Preview refuses out-of-range environment ports" do
    for port <- ["0", "-1", "65536"] do
      System.put_env("MF_PREVIEW_PORT", port)
      assert_raise RuntimeError, ~r/Invalid Preview port/, fn -> read("preview") end
    end
  end

  test "Exam refuses an empty Preview signing credential", c do
    exam_env(c)
    System.put_env("MF_PREVIEW_URL", "http://127.0.0.1:4090")

    File.write!(c.credential, String.duplicate("p", 32))
    assert read("exam")[:mf_exam][:sidecar][:url] == "http://127.0.0.1:4090"

    File.write!(c.credential, "\n")

    assert_raise RuntimeError, ~r/Preview credential requires at least 32 bytes/, fn ->
      read("exam")
    end
  end

  test "Exam startup configuration refusals cannot print encounter credentials or bodies", c do
    path = exam_env(c)
    sentinel = "synthetic-clinical-config-secret-c4d804e1"

    for value <- [
          [%{"exam" => sentinel, "patient_key" => sentinel}],
          [%{"exam" => sentinel, "patient_actor" => nil, "clinician_actor" => sentinel}],
          %{"patient_body" => sentinel},
          [],
          [sentinel]
        ] do
      File.write!(path, JSON.encode!(value))
      error = assert_raise RuntimeError, "Invalid encounter configuration", fn -> read("exam") end
      refute Exception.message(error) =~ sentinel
    end

    File.write!(path, "{\"patient_body\":\"#{sentinel}\"")
    error = assert_raise RuntimeError, "Invalid encounter configuration", fn -> read("exam") end
    refute Exception.message(error) =~ sentinel
  end

  test "Exam malformed deployment values report fixed categories before host startup", c do
    exam_env(c)
    sentinel = "synthetic-startup-credential-3742802a"

    for {key, value, message} <- [
          {"MF_ENCOUNTERS_FILE", Path.join(c.root, sentinel), "Invalid encounter configuration"},
          {"MF_HTTP_PORT", sentinel, "Invalid Exam HTTP port"},
          {"MF_PUBLIC_ORIGIN", "http://[#{sentinel}", "Invalid Exam public origin"},
          {"MF_PREVIEW_URL", "http://[#{sentinel}", "Invalid Preview feed URL"}
        ] do
      old = System.get_env(key)
      System.put_env(key, value)
      error = assert_raise RuntimeError, message, fn -> read("exam") end
      refute Exception.message(error) =~ sentinel
      if old, do: System.put_env(key, old), else: System.delete_env(key)
    end

    System.put_env("MF_DEVICE_TLS_CERTFILE", Path.join(c.root, "certificate"))
    System.put_env("MF_DEVICE_TLS_KEYFILE", Path.join(c.root, "key"))
    System.put_env("MF_DEVICE_BIND_IP", sentinel)

    assert_raise RuntimeError, "Invalid Exam device bind address", fn -> read("exam") end
    System.put_env("MF_DEVICE_BIND_IP", "127.0.0.1")
    System.put_env("MF_DEVICE_TLS_PORT", sentinel)
    assert_raise RuntimeError, "Invalid Exam device TLS port", fn -> read("exam") end
  end

  defp exam_env(c) do
    encounters = Path.join(c.root, "encounters.json")

    File.write!(
      encounters,
      JSON.encode!([
        %{
          "exam" => "fixture",
          "patient_actor" => "patient",
          "clinician_actor" => "clinician",
          "patient_ref" => "Patient/fixture",
          "encounter_ref" => "Encounter/fixture",
          "destination" => "synthetic",
          "patient_key" => String.duplicate("p", 32),
          "clinician_key" => String.duplicate("c", 32)
        }
      ])
    )

    System.put_env(%{
      "MF_LAB" => "1",
      "MF_ENCOUNTERS_FILE" => encounters,
      "MF_ARTIFACT_DIR" => c.root,
      "MF_DEPLOYMENT_UUID" => "129485fb-78f2-4bb1-9731-4fa6506c570b",
      "MF_SECRET_KEY_BASE" => String.duplicate("s", 64),
      "DATABASE_URL" => "postgres://synthetic:synthetic@localhost/synthetic"
    })

    encounters
  end

  defp read(app) do
    @root
    |> Path.join("apps/#{app}/config/runtime.exs")
    |> Config.Reader.read!(env: if(app == "preview", do: :prod, else: :test), target: :host)
  end
end
