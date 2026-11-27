Code.require_file("handheld/lab.exs", __DIR__)
Code.require_file("handheld/process_lab.exs", __DIR__)
Code.require_file("handheld/oracle.exs", __DIR__)
Code.require_file("handheld/soak.exs", __DIR__)

defmodule MedFabric.HandheldAcceptance do
  @moduledoc false
  alias MedFabric.HandheldDemo, as: Demo
  alias MedFabric.Acceptance.{Oracle, ProcessLab, Soak}
  import Oracle, only: [check!: 2, read: 1, sha: 1, integer: 1]

  @root Path.expand("..", __DIR__)
  @suites ~w(paired spot-check browser-microphone)
  @checkpoint_suite "checkpoint-recovery"
  @limits %{
    pending_frames: 16,
    pending_bytes: 262_144,
    spool_bytes: 67_108_864,
    # Preserve the payload baseline; account for MEX1's 48-byte envelope apart.
    frame_bytes: 65_536,
    wire_frame_bytes: 65_584,
    metadata_records: 100_000
  }
  @faults ~w(accepted_before_durable.audio durable_before_ack.audio journal_sync.audio after_object_install.audio manifest_install.all db_completion.all)

  def main(args) do
    {opts, rest, errors} =
      OptionParser.parse(args,
        strict: [
          run_dir: :string,
          suite: :string,
          preview: :string,
          fhir: :string,
          report: :string,
          seconds: :integer,
          installed_consumers: :string
        ]
      )

    suite = opts[:suite] || "paired"
    preview = opts[:preview] || "off"
    seconds = opts[:seconds] || 1740

    check!(
      rest in [[], ["acceptance"]] and errors == [] and
        suite in (@suites ++ ["all", "soak", "paired-faults", @checkpoint_suite]) and
        preview in ["off", "isolated"],
      "Usage: elixir ops/handheld_acceptance.exs --suite paired|spot-check|browser-microphone|paired-faults|checkpoint-recovery|all|soak --preview off|isolated [--fhir hapi] [--run-dir DIR] [--report FILE] [--seconds 3..1740] [--installed-consumers DIR]"
    )

    check!(
      if(suite == "soak",
        do: seconds in 3..1740,
        else: is_nil(opts[:seconds])
      ),
      "Soak requires a duration from 3 to 1740 seconds"
    )

    check!(
      not (suite == "all" or (suite == "soak" and seconds == 1740)) or
        is_binary(opts[:installed_consumers]),
      "Release native and full soak gates require verified installed archive consumers"
    )

    required = if suite == "all", do: @suites, else: [suite]

    check!(
      "spot-check" not in required or opts[:fhir] == "hapi",
      "Spot-check requires --fhir hapi"
    )

    temporary? = is_nil(opts[:run_dir])

    directory =
      Path.expand(opts[:run_dir] || Path.join(System.tmp_dir!(), "mf-native-#{Demo.token(12)}"))

    report_path =
      if opts[:report],
        do: Path.expand(opts[:report]),
        else: if(temporary?, do: nil, else: Path.join(directory, "report.json"))

    case File.lstat(directory) do
      {:ok, %{type: :directory}} ->
        check!(File.ls!(directory) == [], "Choose a new empty run directory")

      {:error, :enoent} ->
        :ok

      _ ->
        raise "Unsafe lab directory"
    end

    Process.flag(:trap_exit, true)
    started = System.monotonic_time(:millisecond)

    ProcessLab.init(
      directory,
      %{
        "paired" => 900_000,
        "paired-faults" => 180_000,
        @checkpoint_suite => 120_000,
        "spot-check" => 300_000,
        "browser-microphone" => 300_000,
        "all" => 1_500_000,
        "soak" => (seconds + 180) * 1000
      }[suite]
    )

    Process.put(:mf_report, %{
      schema: "medfabric.acceptance.v2",
      runner: "elixir-native",
      passed: false,
      required_suites: required,
      skipped_required: required,
      configured_limits: @limits,
      scenarios: %{},
      service_versions: %{},
      source_identities: %{},
      review_revisions: [],
      fhir_external_ids: [],
      raw_payload_digests: %{},
      oracle_payload_digests: %{},
      clock_holdout_violations: nil,
      unknown_command_outcome_exercised: false,
      preview_os_process_killed: false,
      bounds_respected: false
    })

    try do
      prerequisites!()
      Demo.prepare!(directory)
      lab = initialize!(directory, required, preview, opts[:installed_consumers])

      Enum.reduce(required, lab, fn name, lab ->
        start = System.monotonic_time(:millisecond)

        lab =
          case name do
            "paired" ->
              paired!(lab)

            "paired-faults" ->
              lab = monitor_faults!(lab)
              network_denials!(lab)
              lab

            @checkpoint_suite ->
              {lab, _} =
                paired_case!(lab, "journal_sync", %{"seconds" => 4}, "journal_sync.audio")

              lab

            "soak" ->
              soak!(
                lab,
                seconds,
                Path.dirname(report_path || Path.join(directory, "report.json"))
              )

            "spot-check" ->
              spot!(lab)

            "browser-microphone" ->
              browser!(lab)
          end

        scenario(name <> "-elapsed-seconds", (System.monotonic_time(:millisecond) - start) / 1000)
        update(:skipped_required, &List.delete(&1, name))
        lab
      end)

      record(%{passed: true})
    rescue
      error ->
        # Keep reports non-secret; the stack location identifies the failing gate.
        location =
          Enum.find(__STACKTRACE__, fn {module, _, _, _} ->
            module in [__MODULE__, Oracle, ProcessLab]
          end)

        record(%{
          passed: false,
          error: inspect(error.__struct__),
          failure_location: format_location(location)
        })

        if File.dir?(Path.join(directory, "logs")) do
          failure = Path.join(directory, "logs/native-failure.log")
          File.write!(failure, Exception.format(:error, error, __STACKTRACE__))
          File.chmod!(failure, 0o600)
        end

        IO.puts(
          :stderr,
          "Native acceptance failed at #{inspect(format_location(location))}; inspect the private lab logs"
        )
    after
      try do
        ProcessLab.close!()
      rescue
        _ -> record(%{passed: false, cleanup_error: "Owned process cleanup failed"})
      end

      if name = Process.get(:mf_hapi_container) do
        try do
          System.cmd("timeout", ["15", "docker", "rm", "-f", name], stderr_to_stdout: true)

          case System.cmd("timeout", ["5", "docker", "inspect", name], stderr_to_stdout: true) do
            {_, 0} -> record(%{passed: false, cleanup_error: "Owned HAPI container still exists"})
            _ -> :ok
          end
        rescue
          _ -> record(%{passed: false, cleanup_error: "Owned HAPI cleanup failed"})
        end
      end

      record(%{
        elapsed_seconds: (System.monotonic_time(:millisecond) - started) / 1000,
        processes: ProcessLab.evidence()
      })

      if report_path, do: write_report!(report_path, report())
      # Preserve a failed run for diagnosis, but never silently retain a success
      # full of synthetic credentials. Explicit --run-dir is always retained.
      if temporary? and report().passed, do: File.rm_rf!(directory)
      unless report().passed, do: IO.puts(:stderr, "Private lab: #{directory}")
    end

    if report().passed, do: IO.puts("Passed: #{Enum.join(required, ", ")}"), else: System.halt(1)
  end

  defp format_location({module, function, _, meta}),
    do: %{module: inspect(module), function: to_string(function), line: meta[:line]}

  defp format_location(_), do: nil
  defp report, do: Process.get(:mf_report)
  defp record(values), do: Process.put(:mf_report, Map.merge(report(), values))
  defp update(key, fun), do: record(%{key => fun.(Map.fetch!(report(), key))})
  defp scenario(name, values), do: update(:scenarios, &Map.put(&1, name, values))
  defp append(key, value), do: update(key, &(&1 ++ [value]))

  defp prerequisites! do
    for binary <- ~w(mix elixir initdb postgres psql openssl flock bwrap setsid timeout kill) do
      check!(System.find_executable(binary) != nil, "Missing prerequisite #{binary}")
    end

    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok = :httpc.set_options(cookies: :enabled)
  end

  defp initialize!(directory, required, preview, installed_consumers) do
    cfg = read(Path.join(directory, "server.json"))
    client = read(Path.join(directory, "handheld-a.json"))

    env =
      System.get_env()
      |> Enum.reject(fn {key, _} ->
        String.starts_with?(key, "PG") or
          key in ~w(SSLKEYLOGFILE MIX_ENV MIX_EXS MIX_TARGET MIX_BUILD_PATH MIX_BUILD_ROOT MIX_DEPS_PATH MIX_LOCKFILE DATABASE_URL MF_LAB)
      end)
      |> Map.new()
      |> Map.merge(%{
        "PGHOST" => "127.0.0.1",
        "PGPORT" => to_string(cfg["postgres_port"]),
        "PGUSER" => "lab",
        "PGDATABASE" => "postgres",
        "PGPASSWORD" => File.read!(Path.join(directory, "postgres.credential"))
      })

    lab = %{
      dir: directory,
      cfg: cfg,
      client: client,
      env: env,
      server: nil,
      preview: nil,
      preview?: preview == "isolated",
      installed_consumers: if(installed_consumers, do: Path.expand(installed_consumers))
    }

    if lab.installed_consumers do
      inputs = Path.join(lab.installed_consumers, "artifacts.json")
      verified = read(inputs)
      registry = read(Path.join(lab.installed_consumers, "registry.json"))

      check!(
        verified["schema"] == "medfabric.detached_verified.v2",
        "Missing verified archive inputs"
      )

      check!(registry["kind"] == verified["registry"], "Installed registry identity differs")

      installed =
        for role <- ~w(exam handheld preview) do
          output = at(lab, "#{role}-installed.json")

          run!(lab, "verify-installed-#{role}", "elixir", [
            Path.join(@root, "ops/detached_artifacts.exs"),
            "installed",
            inputs,
            Path.join(lab.installed_consumers, role),
            role,
            output
          ])

          read(output)
        end

      record(%{
        installed_artifacts: installed,
        artifact_manifest_sha256: verified["manifest_sha256"],
        registry: verified["registry"],
        registry_origin: registry["url"]
      })
    end

    # Record hashes/coordinates, never raw selector content (which could contain
    # embedded credentials). Git status is recorded only if a real repo exists.
    identities =
      for repo <- ~w(weld med_ex med_fabric),
          path = if(repo == "med_fabric", do: @root, else: Path.join(Path.dirname(@root), repo)),
          File.exists?(Path.join(path, ".git")),
          into: %{} do
        {repo,
         %{
           head: capture!("git", ["rev-parse", "HEAD"], path, env),
           dirty: capture!("git", ["status", "--porcelain"], path, env) != ""
         }}
      end

    locks =
      Path.wildcard(Path.join(@root, "**/mix.lock"))
      |> Enum.reject(fn p ->
        Enum.any?(Path.split(Path.relative_to(p, @root)), &(&1 in ["deps", "_build"]))
      end)

    selection = Path.join(@root, ".mix_sources.json")

    record(%{
      seed: client["seed"],
      source_identities: identities,
      dependency_selection_sha256:
        if(File.regular?(selection), do: sha(File.read!(selection)), else: nil),
      dependency_lock_sha256: Map.new(locks, &{Path.relative_to(&1, @root), sha(File.read!(&1))}),
      service_versions: %{
        elixir: capture!("elixir", ["--version"], @root, env),
        postgres: capture!("postgres", ["--version"], @root, env)
      }
    })

    run!(lab, "initdb", "initdb", [
      "-D",
      at(lab, "pgdata"),
      "-U",
      "lab",
      "--auth-local=trust",
      "--auth-host=scram-sha-256",
      "--pwfile",
      at(lab, "postgres.credential"),
      "--no-locale"
    ])

    postgres =
      launch!(lab, "postgres", "postgres", [
        "-D",
        at(lab, "pgdata"),
        "-k",
        at(lab, "pghost"),
        "-h",
        "127.0.0.1",
        "-p",
        to_string(cfg["postgres_port"])
      ])

    ProcessLab.wait!(fn -> sql_ready?(lab) end, 30_000, postgres, "PostgreSQL")
    lab = if "spot-check" in required, do: hapi!(lab), else: lab
    lab = if lab.preview?, do: start_preview!(lab), else: lab

    lab = put_in(lab.cfg["checkpoint_timings"], at(lab, "barriers/checkpoint-timings.jsonl"))

    save(at(lab, "server.json"), lab.cfg)
    lab = start_server!(lab)

    relay =
      launch!(lab, "tls-relay", "elixir", [
        Path.join(@root, "ops/handheld_demo.exs"),
        "relay",
        "--run-dir",
        directory
      ])

    ProcessLab.wait!(
      fn -> log_contains?(relay, "TLS relay ready") end,
      20_000,
      relay,
      "TLS relay"
    )

    login!(lab)
  end

  defp at(lab, path), do: Path.join(lab.dir, path)

  defp save(path, value) do
    temp = path <> ".tmp-" <> Demo.token(6)
    File.write!(temp, JSON.encode_to_iodata!(value), [:exclusive])
    File.chmod!(temp, 0o600)
    File.rename!(temp, path)
  end

  defp write_report!(path, value) do
    File.mkdir_p!(Path.dirname(path))
    save(path, value)
  end

  defp capture!(command, args, cwd, env, timeout \\ "8") do
    # timeout also bounds psql calls used in readiness polling.
    case System.cmd("timeout", [timeout, command | args],
           cd: cwd,
           env:
             Enum.to_list(Map.merge(Map.new(System.get_env(), fn {k, _} -> {k, nil} end), env)),
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      {_, code} -> raise("#{command} exited #{code}")
    end
  end

  defp sql!(lab, statement, timeout \\ "8"),
    do:
      capture!(
        "psql",
        ["-XAt", "-v", "ON_ERROR_STOP=1", "-c", statement],
        @root,
        lab.env,
        timeout
      )

  defp sql_ready?(lab) do
    sql!(lab, "SELECT current_setting('data_directory')") == at(lab, "pgdata")
  rescue
    RuntimeError -> false
  end

  defp request(method, url, headers \\ [], body \\ nil) do
    mime =
      Enum.find_value(headers, "application/json", fn {k, v} -> if k == "content-type", do: v end)

    headers = Enum.reject(headers, fn {k, _} -> k == "content-type" end)
    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    request =
      if body == nil,
        do: {to_charlist(url), headers},
        else: {to_charlist(url), headers, to_charlist(mime), JSON.encode!(body)}

    case :httpc.request(
           method,
           request,
           [timeout: 35_000, connect_timeout: 2_000, autoredirect: true],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} -> {status, body}
      {:error, reason} -> raise("HTTP transport failed: #{inspect(elem_or_self(reason))}")
    end
  end

  defp elem_or_self(value) when is_tuple(value), do: elem(value, 0)
  defp elem_or_self(value), do: value

  defp get!(url) do
    {status, bytes} = request(:get, url)
    check!(status == 200, "Unexpected HTTP status #{status}")
    bytes
  end

  defp hapi!(lab) do
    e = hd(lab.cfg["encounters"])
    base = String.trim_trailing(e["destination"], "/")
    uri = URI.parse(base)

    check!(
      uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"] and
        is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
      "Use a dedicated loopback synthetic HAPI endpoint"
    )

    if is_nil(System.get_env("FHIR_BASE_URL")) do
      name = "fabric-hapi-#{Demo.token(8)}"
      port = URI.parse(base).port
      Process.put(:mf_hapi_container, name)

      launch!(lab, "hapi", "docker", [
        "run",
        "--rm",
        "--name",
        name,
        "-p",
        "127.0.0.1:#{port}:8080",
        System.get_env("MF_HAPI_IMAGE", "hapiproject/hapi:v7.6.0")
      ])
    end

    cap =
      ProcessLab.wait!(
        fn ->
          try do
            base |> Kernel.<>("/metadata") |> get!() |> JSON.decode!()
          rescue
            _ -> false
          end
        end,
        120_000,
        nil,
        "HAPI R4 capability"
      )

    check!(String.starts_with?(cap["fhirVersion"], "4.0"), "FHIR R4 required")
    update(:service_versions, &Map.put(&1, :hapi, cap["software"]))

    device = %{
      "status" => "active",
      "deviceName" => [%{"name" => "Synthetic PLXS fixture", "type" => "user-friendly-name"}]
    }

    resources = [
      {e["patient_ref"], %{}},
      {e["encounter_ref"],
       %{
         "status" => "in-progress",
         "class" => %{
           "system" => "http://terminology.hl7.org/CodeSystem/v3-ActCode",
           "code" => "AMB"
         },
         "subject" => %{"reference" => e["patient_ref"]}
       }},
      {"Device/synthetic-plx", device}
    ]

    for {ref, attrs} <- resources do
      [type, id] = String.split(ref, "/")

      {status, _} =
        request(
          :put,
          base <> "/" <> ref,
          [{"if-none-match", "*"}, {"content-type", "application/fhir+json"}],
          Map.merge(attrs, %{"resourceType" => type, "id" => id})
        )

      if type == "Device" and status == 412 do
        check!(
          JSON.decode!(get!(base <> "/" <> ref))["deviceName"] == device["deviceName"],
          "Foreign synthetic device"
        )
      else
        check!(status in [200, 201], "FHIR fixture seed returned #{status}")
      end
    end

    %{
      lab
      | cfg:
          Map.update!(lab.cfg, "encounters", fn [first | rest] ->
            [Map.put(first, "destination", base) | rest]
          end)
    }
  end

  defp launch!(lab, name, exe, args, cwd \\ @root, env \\ nil),
    do: ProcessLab.launch!(name, exe, args, cwd, env || lab.env)

  defp run!(lab, name, exe, args, cwd \\ @root, env \\ nil, timeout \\ 180_000),
    do: ProcessLab.run!(name, exe, args, cwd, env || lab.env, timeout)

  defp log_contains?(child, text),
    do: File.regular?(child.log) and String.contains?(File.read!(child.log), text)

  # Host root is unmapped in an unprivileged user namespace. Build the
  # artifact's ancestor chain inside that namespace and mount other paths read-only.
  defp sandbox_root(lab_dir) do
    lab_dir
    |> Path.split()
    |> Enum.reduce({[], nil}, fn
      "/", {args, nil} ->
        {args, "/"}

      name, {args, parent} ->
        siblings =
          if parent in ["/tmp", "/var/tmp"] do
            []
          else
            (File.ls!(parent) -- [name])
            |> Enum.sort()
            |> Enum.flat_map(&sandbox_sibling(Path.join(parent, &1)))
          end

        next = Path.join(parent, name)
        {args ++ siblings ++ ["--dir", next], next}
    end)
    |> elem(0)
  end

  defp sandbox_sibling(path) when path in ["/dev", "/proc"], do: []

  defp sandbox_sibling(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> ["--symlink", File.read_link!(path), path]
      {:ok, %{type: type}} when type in [:regular, :directory] -> ["--ro-bind", path, path]
      _ -> []
    end
  end

  defp isolate!(lab, role, exe, args, config, env \\ nil) do
    cwd =
      if lab.installed_consumers,
        do: Path.join(lab.installed_consumers, role),
        else: Path.join([@root, "apps", role])

    base =
      ["--die-with-parent", "--unshare-pid"] ++
        sandbox_root(lab.dir) ++
        [
          "--dev-bind",
          "/dev",
          "/dev",
          "--proc",
          "/proc",
          "--bind",
          cwd,
          cwd,
          "--tmpfs",
          lab.dir,
          "--dir",
          at(lab, "runtime-tmp"),
          "--tmpfs",
          at(lab, "runtime-tmp"),
          "--setenv",
          "TMPDIR",
          at(lab, "runtime-tmp")
        ]

    {files, dirs} =
      case role do
        "exam" ->
          {~w(server.json encounters.json cert.pem key.pem device.credential secondary.credential preview.credential),
           ~w(artifact barriers)}

        "preview" ->
          {["preview.credential", "preview.json"], []}

        "handheld" ->
          cfg = read(config)
          spool = "spool/" <> cfg["acquisition"]
          File.mkdir_p!(at(lab, spool))
          File.chmod!(at(lab, spool), 0o700)

          {[Path.relative_to(config, lab.dir), "ca.pem", Path.basename(cfg["credential_file"])],
           [spool]}
      end

    mounts =
      Enum.flat_map(dirs, fn n ->
        p = at(lab, n)
        ["--dir", p, "--bind", p, p]
      end) ++
        Enum.flat_map(files, fn n ->
          p = at(lab, n)
          ["--ro-bind", p, p]
        end)

    env = env || lab.env
    env = if lab.installed_consumers, do: Map.put(env, "MIX_ENV", "prod"), else: env

    env =
      if not is_nil(lab.installed_consumers) and role == "exam" do
        # The composed application's bootstrap reapplies its packaged config.
        # Supply the complete disposable deployment through that public runtime
        # boundary before Mix and the application evaluate either config entry.
        values = %{
          "MF_LAB" => "1",
          "MF_DEPLOYMENT_UUID" => lab.cfg["deployment_uuid"],
          "MF_ENCOUNTERS_FILE" => at(lab, "encounters.json"),
          "DATABASE_URL" => lab.cfg["database_url"],
          "MF_ARTIFACT_DIR" => lab.cfg["artifact_dir"],
          "MF_SECRET_KEY_BASE" => lab.cfg["cookie_secret"],
          "MF_HTTP_PORT" => to_string(lab.cfg["http_port"]),
          "MF_DEVICE_TLS_PORT" => to_string(lab.cfg["tls_port"]),
          "MF_DEVICE_TLS_CERTFILE" => lab.cfg["cert"],
          "MF_DEVICE_TLS_KEYFILE" => lab.cfg["key"],
          "MF_DEVICE_BIND_IP" => "127.0.0.1",
          "MF_PUBLIC_ORIGIN" => "http://localhost:#{lab.cfg["http_port"]}"
        }

        values =
          if lab.cfg["preview_url"],
            do:
              Map.merge(values, %{
                "MF_PREVIEW_URL" => lab.cfg["preview_url"],
                "MF_PREVIEW_CREDENTIAL_FILE" => lab.cfg["preview_credential_file"]
              }),
            else: values

        Map.merge(env, values)
      else
        env
      end

    env =
      if role == "exam",
        do: env,
        else:
          Map.reject(env, fn {key, _} ->
            String.starts_with?(key, ["PG", "DATABASE_", "FHIR_"]) or
              (String.starts_with?(key, "MF_") and
                 not (role == "preview" and
                        key in [
                          "MF_PREVIEW_CREDENTIAL_FILE",
                          "MF_PREVIEW_PORT",
                          "MF_PREVIEW_CONFIG"
                        ]))
          end)

    # Check the mounted namespace, not just the intended mount list. The
    # marker is emitted by the same owned process before it execs the app.
    proof =
      if role == "exam",
        do: "test -r \"$1/server.json\"",
        else: """
        test ! -e "$1/server.json" && test ! -e "$1/artifact" && test ! -e "$1/pgdata" &&
        test ! -e "$1/postgres.credential" && test ! -e "$1/key.pem" &&
        test -z "${PGPASSWORD-}${DATABASE_URL-}${FHIR_BASE_URL-}" &&
        if [ "$2" = preview ]; then test ! -e "$1/spool" && test -r "$1/preview.credential";
        else test ! -e "$1/preview.credential"; fi
        """

    script =
      proof <>
        "\nstatus=$?; [ \"$status\" -eq 0 ] || exit 71; echo \"Role isolation verified: $2\"; shift 2; exec \"$@\""

    launch!(
      lab,
      role <> "-" <> Path.basename(exe),
      "bwrap",
      base ++
        mounts ++
        ["--remount-ro", "/", "--", "sh", "-c", script, "lab-role", lab.dir, role, exe | args],
      cwd,
      env
    )
  end

  defp start_preview!(lab) do
    cfg = Map.put(lab.cfg, "preview_url", "http://127.0.0.1:#{lab.cfg["preview_port"]}")

    env =
      Map.merge(lab.env, %{
        "MF_PREVIEW_CONFIG" => at(lab, "preview.json"),
        "MF_PREVIEW_CREDENTIAL_FILE" => cfg["preview_credential_file"],
        "MF_PREVIEW_PORT" => to_string(cfg["preview_port"])
      })

    preview =
      isolate!(
        lab,
        "preview",
        "mix",
        ["run", "--no-halt", "-e", "IO.puts(\"Synthetic preview ready\")"],
        nil,
        env
      )

    ProcessLab.wait!(
      fn ->
        log_contains?(preview, "Synthetic preview ready") and tcp_ready?(cfg["preview_port"])
      end,
      30_000,
      preview,
      "Preview listener"
    )

    check!(
      log_contains?(preview, "Role isolation verified: preview"),
      "Preview isolation proof missing"
    )

    record(%{preview_role_isolation_verified: true})
    %{lab | cfg: cfg, preview: preview}
  end

  defp tcp_ready?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  end

  defp start_server!(lab) do
    save(at(lab, "encounters.json"), lab.cfg["encounters"])

    server =
      isolate!(
        lab,
        "exam",
        "mix",
        [
          "run",
          "--no-start",
          "--no-halt",
          Path.join(@root, "ops/run_exam.exs"),
          "--config",
          at(lab, "server.json")
        ],
        nil
      )

    ProcessLab.wait!(
      fn -> log_contains?(server, "Synthetic exam ready") end,
      45_000,
      server,
      "Exam"
    )

    %{lab | server: server}
  end

  defp login!(lab) do
    e = hd(lab.cfg["encounters"])
    base = "http://localhost:#{lab.cfg["http_port"]}/encounters/#{e["exam"]}"
    page = get!(base <> "?" <> URI.encode_query(%{"key" => e["clinician_key"]}))
    [tag] = Regex.run(~r/<meta\b[^>]*name=["']csrf-token["'][^>]*>/i, page)
    [_, csrf] = Regex.run(~r/content=["']([^"']+)["']/i, tag)
    Map.merge(lab, %{base: base, csrf: csrf})
  end

  defp action!(lab, id, action, fields \\ %{}, expected \\ 200) do
    {status, _} =
      request(
        :post,
        lab.base <>
          if(action == "deliver",
            do: "/observations/#{id}/deliver",
            else: "/acquisitions/#{id}/action"
          ),
        [{"x-csrf-token", lab.csrf}],
        fields
        |> Map.put("action", action)
        |> then(fn body ->
          if action == "review",
            do: Map.put_new(body, "request_id", sha(JSON.encode!(body))),
            else: body
        end)
      )

    check!(status == expected, "#{action} returned #{status}, expected #{expected}")
  end

  defp client!(lab, profile, name, settings) do
    cfg =
      Map.merge(
        lab.client,
        Map.merge(
          %{
            "acquisition" =>
              name <> "-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower),
            "preview" => lab.preview?
          },
          settings
        )
      )

    save(at(lab, cfg["acquisition"] <> ".json"), cfg)
    {cfg, run_client!(lab, cfg, profile)}
  end

  defp run_client!(lab, cfg, profile) do
    path = at(lab, cfg["acquisition"] <> ".json")

    entry =
      if cfg["local_monitor_fault"],
        do: [Path.join(@root, "apps/handheld/integration/local_monitor_fault.exs")],
        else: ["-e", "MedExHandheld.CLI.main(System.argv())"]

    isolate!(
      lab,
      "handheld",
      "mix",
      ["run"] ++
        entry ++
        [
          "--",
          "--config",
          path,
          "--scenario",
          profile
        ],
      path
    )
  end

  defp manifest!(lab, cfg) do
    root = at(lab, "artifact/acquisitions-v2/" <> sha(cfg["acquisition"]))
    bytes = File.read!(Path.join(root, "manifest.mej1"))
    digest = sha(bytes)

    check!(
      sql!(
        lab,
        "SELECT digest FROM acquisition_manifests WHERE acquisition_id='#{cfg["acquisition"]}'"
      ) == digest,
      "Manifest DB digest differs"
    )

    {root, digest, JSON.decode!(bytes)}
  end

  defp count!(lab, table, where),
    do: sql!(lab, "SELECT count(*) FROM #{table} WHERE #{where}") |> integer()

  defp barrier(lab, name), do: at(lab, "barriers/#{name}.armed")
  defp reached(path), do: String.replace_suffix(path, ".armed", ".reached")
  defp arm!(path), do: File.write!(path, "", [:exclusive])

  defp outage!(lab, fun) do
    path = at(lab, "outage")
    arm!(path)

    try do
      fun.()
    after
      File.rm!(path)
    end
  end

  defp command_and_stall!(lab, cfg, child) do
    id = cfg["acquisition"]

    ProcessLab.wait!(
      fn -> count!(lab, "stream_attempts", "acquisition_id='#{id}'") == 2 end,
      30_000,
      child,
      "paired admission"
    )

    viewer =
      if lab.preview? do
        ready = at(lab, "viewer.ready")

        viewer =
          launch!(lab, "rtc-viewer", "node", [
            Path.join(@root, "ops/handheld/monitor_viewer.mjs"),
            at(lab, "server.json"),
            id,
            ready
          ])

        ProcessLab.wait!(fn -> File.regular?(ready) end, 30_000, viewer, "actual preview media")
        viewer
      end

    action!(lab, id, "monitor_gain", %{"gain" => "half"})

    ProcessLab.wait!(
      fn ->
        count!(
          lab,
          "acquisition_facts",
          "acquisition_id='#{id}' AND kind='command_applied'"
        ) >
          0
      end,
      30_000,
      child,
      "applied monitor command"
    )

    armed = barrier(lab, "writer_stall.ecg")
    arm!(armed)
    ProcessLab.wait!(fn -> File.regular?(reached(armed)) end, 30_000, child, "ECG writer stall")

    counters = fn ->
      {sql!(
         lab,
         "SELECT coalesce(max((receipt->>'journal_generation')::bigint),0) FROM stream_attempts WHERE acquisition_id='#{id}' AND stream='audio'"
       )
       |> integer(),
       sql!(
         lab,
         "SELECT floor(extract(epoch FROM expires_at)*1000)::bigint FROM acquisition_sessions WHERE id='#{id}'"
       )
       |> integer()}
    end

    device = Enum.at(lab.cfg["devices"], 1)

    {other_cfg, other_child} =
      client!(lab, "paired_exam", "concurrent-encounter", %{
        "seconds" => 60,
        "device" => device["id"],
        "encounter" => device["exam"],
        "credential_file" => device["credential_file"]
      })

    other_id = other_cfg["acquisition"]
    {audio, beats} = counters.()

    ProcessLab.wait!(
      fn ->
        sql!(lab, """
        SELECT count(DISTINCT stream) FROM stream_attempts
        WHERE acquisition_id='#{other_id}' AND (receipt->>'journal_generation')::bigint>0
        """) == "2"
      end,
      15_000,
      other_child,
      "both streams in the independent encounter remain durable during the stall"
    )

    Process.sleep(2_000)
    {new_audio, new_beats} = counters.()
    File.rm!(reached(armed))
    check!(new_audio > audio and new_beats > beats, "Audio or control stalled with ECG")

    record(%{
      sibling_stall_audio_receipts: new_audio - audio,
      sibling_stall_lease_extension_ms: new_beats - beats
    })

    lab =
      if viewer do
        ProcessLab.kill!(lab.preview)
        ProcessLab.await_success!(viewer, 15_000)
        record(%{preview_os_process_killed: true})
        start_preview!(lab)
      else
        lab
      end

    {lab, {other_cfg, other_child}}
  end

  defp paired_case!(lab, name, settings, fault \\ nil) do
    IO.puts("Paired fixture: #{name}")
    armed = if fault, do: barrier(lab, fault)
    if armed, do: arm!(armed)
    {cfg, child} = client!(lab, "paired_exam", name, settings)

    if cfg["local_monitor_fault"] == "stop" do
      marker = at(lab, "spool/#{cfg["acquisition"]}/monitor-fault.json")

      ProcessLab.wait!(
        fn -> File.regular?(marker) end,
        25_000,
        child,
        "durable progress with monitor suspended"
      )

      action!(lab, cfg["acquisition"], "monitor_gain", %{"gain" => "half"})

      ProcessLab.wait!(
        fn ->
          count!(
            lab,
            "acquisition_facts",
            "acquisition_id='#{cfg["acquisition"]}' AND kind='command_outcome_unknown'"
          ) > 0
        end,
        15_000,
        child,
        "stalled monitor command remains unknown"
      )

      record(%{unknown_command_outcome_exercised: true})

      dir = Path.dirname(marker)
      File.write!(Path.join(dir, "check-monitor-queue"), "")

      ProcessLab.wait!(
        fn -> File.exists?(Path.join(dir, "monitor-queue-checked")) end,
        5_000,
        child,
        "bounded monitor backlog after command reconciliation"
      )

      action!(lab, cfg["acquisition"], "stop")
    end

    {lab, concurrent} =
      if name == "baseline" do
        {lab, concurrent} = command_and_stall!(lab, cfg, child)
        outage!(lab, fn -> Process.sleep(10_000) end)
        {lab, concurrent}
      else
        {lab, nil}
      end

    {lab, staged} =
      if armed do
        ProcessLab.wait!(fn -> File.regular?(reached(armed)) end, 30_000, child, "fault #{fault}")

        staged =
          if fault in ["manifest_install.all", "db_completion.all"] do
            [digest, encoded] =
              sql!(
                lab,
                "SELECT digest,encode(bytes,'hex') FROM acquisition_manifest_staging WHERE acquisition_id='#{cfg["acquisition"]}'"
              )
              |> String.split("|")

            bytes = Base.decode16!(encoded, case: :mixed)
            check!(sha(bytes) == digest, "Staged manifest digest differs")
            {digest, bytes}
          end

        if fault == "journal_sync.audio" do
          backend = armed |> reached() |> File.read!() |> integer()

          check!(
            sql!(lab, "SELECT pg_terminate_backend(#{backend}, 3000)") == "t",
            "Could not terminate the checkpoint transaction backend"
          )

          File.rm!(reached(armed))
          {lab, staged}
        else
          ProcessLab.kill!(lab.server)
          File.rm!(reached(armed))
          {lab |> start_server!() |> login!(), staged}
        end
      else
        {lab, nil}
      end

    ProcessLab.await_success!(child, 180_000)

    if concurrent do
      {other_cfg, other_child} = concurrent
      ProcessLab.await_success!(other_child, 180_000)
      {root, digest, manifest} = manifest!(lab, other_cfg)
      result = Oracle.verify!(lab.dir, other_cfg, root, manifest)
      scenario("concurrent-encounter", Map.put(result, :manifest_digest, digest))
    end

    cfg =
      if cfg["local_monitor_fault"] == "stop" do
        cutoffs =
          Map.new(~w(audio ecg), fn stream ->
            state = read(at(lab, "spool/#{cfg["acquisition"]}/#{stream}/source.json"))
            rate = if stream == "audio", do: 48_000, else: 250

            check!(
              state["done"] and state["sample"] > 0 and state["sample"] < cfg["seconds"] * rate,
              "Operator stop did not terminate #{stream} early"
            )

            {stream, state["sample"]}
          end)

        Map.put(cfg, "restart_cutoffs", cutoffs)
      else
        cfg
      end

    {root, digest, manifest} = manifest!(lab, cfg)

    result =
      Oracle.verify!(lab.dir, cfg, root, manifest)
      |> Map.merge(%{
        manifest_digest: digest,
        manifest_path: Path.relative_to(Path.join(root, "manifest.mej1"), lab.dir)
      })

    result =
      if staged do
        check!(
          staged == {digest, File.read!(Path.join(root, "manifest.mej1"))},
          "Staged manifest bytes changed after restart"
        )

        Map.put(result, :staged_bytes_preserved, true)
      else
        result
      end

    if name == "baseline" do
      checks = Map.values(result.clock_holdouts)

      check!(
        Enum.all?(checks, &(&1.tested > 0 and &1.violations == 0)),
        "Clock holdout not bounded or outside interval"
      )

      record(
        Map.take(result, [
          :raw_payload_digests,
          :oracle_payload_digests,
          :duplicate_logical_frames
        ])
      )

      record(%{clock_holdout_violations: 0})
      record(Oracle.monitor!(lab.dir, cfg, manifest))
    end

    choice = review_choice(manifest, name)
    id = cfg["acquisition"]
    action!(lab, id, "review", %{"digest" => String.duplicate("0", 64), "choice" => choice}, 409)
    action!(lab, id, "review", %{"digest" => digest, "choice" => choice})
    action!(lab, id, "review", %{"digest" => digest, "choice" => choice})

    action!(
      lab,
      id,
      "review",
      %{"digest" => digest, "choice" => Map.put(choice, "note", "Conflicting immutable edit")},
      409
    )

    result = Map.put(result, :review_decision, choice["decision"])

    result =
      if lab.preview? and name in ["baseline", "source-gap"] do
        run!(lab, "paired-review-ui", "node", [
          Path.join(@root, "ops/handheld/paired_review.mjs"),
          at(lab, "server.json"),
          id,
          choice["decision"]
        ])

        Map.put(result, :browser_review_verified, true)
      else
        result
      end

    append(:review_revisions, digest)
    scenario(name, result)
    {lab, result}
  end

  defp review_choice(manifest, name) do
    cond do
      name == "spool-capacity" ->
        %{"decision" => "reject", "note" => "Verified synthetic interruption", "metrics" => []}

      name == "source-reset" ->
        %{"decision" => "repeat", "note" => "Verified synthetic interruption", "metrics" => []}

      true ->
        stream =
          if manifest["streams"]["audio"]["index"]["segments"] != [], do: "audio", else: "ecg"

        case manifest["streams"][stream]["index"]["segments"] do
          [] ->
            %{"decision" => "reject", "note" => "No verified samples", "metrics" => []}

          [first | rest] ->
            last =
              case rest do
                [next | _] when name == "baseline" -> next
                _ -> first
              end

            %{
              "decision" => if(manifest["defects"] == [], do: "complete", else: "partial"),
              "note" => "Synthetic review",
              "ranges" => [
                %{
                  "stream" => stream,
                  "first" => first["first_sample"],
                  "end" => last["end_sample"]
                }
              ],
              "metrics" => [],
              "acknowledged" => manifest["defects"]
            }
        end
    end
  end

  defp await_soak!(lab, cfg, child, started, file) do
    key = make_ref()
    children = Enum.reject(ProcessLab.children(), &(&1.name == "initdb"))
    take_sample = fn previous -> soak_sample(lab, cfg, started, children, previous) end
    baseline = take_sample.(nil)
    :ok = Soak.append!(file, baseline)
    Process.send_after(self(), {key, baseline, %{}}, Soak.interval_ms())

    result =
      ProcessLab.wait!(
        fn ->
          case ProcessLab.status(child) do
            nil ->
              receive do
                {^key, previous, streaks} ->
                  point = take_sample.(previous)
                  :ok = Soak.append!(file, point)
                  Soak.print(point)
                  {streaks, failures} = Soak.assess(point, streaks)

                  case failures do
                    [] ->
                      interval = Soak.interval_ms()
                      spent = System.monotonic_time(:millisecond) - started - point.elapsed_ms
                      Process.send_after(self(), {key, point, streaks}, max(0, interval - spent))
                      false

                    _ ->
                      {:stopped, failures}
                  end
              after
                0 -> false
              end

            status ->
              :ok = Soak.append!(file, %{take_sample.(nil) | phase: "client_exited"})
              {:exited, status}
          end
        end,
        (cfg["seconds"] + 120) * 1_000,
        nil,
        "soak capture and seal"
      )

    case result do
      {:exited, status} ->
        {status, []}

      {:stopped, failures} ->
        IO.puts(:stderr, "Soak stopped on performance guardrail: #{JSON.encode!(failures)}")
        {ProcessLab.stop!(child, "TERM"), failures}
    end
  end

  defp soak_sample(lab, cfg, started, children, previous) do
    root = at(lab, "spool/" <> cfg["acquisition"])
    elapsed = System.monotonic_time(:millisecond) - started
    Soak.sample(root, cfg["seconds"], elapsed, previous, children, fn -> soak_postgres(lab) end)
  end

  defp soak_postgres(lab) do
    sql!(
      lab,
      """
      SELECT json_build_object(
        'activity', (SELECT coalesce(json_agg(a), '[]') FROM (
          SELECT state, wait_event_type, wait_event, count(*)
          FROM pg_stat_activity
          WHERE datname = current_database() AND pid <> pg_backend_pid()
          GROUP BY 1,2,3
        ) a),
        'commits', xact_commit, 'rollbacks', xact_rollback, 'deadlocks', deadlocks,
        'temp_bytes', temp_bytes, 'blocks_read', blks_read, 'blocks_hit', blks_hit)
      FROM pg_stat_database WHERE datname = current_database()
      """,
      "2"
    )
    |> JSON.decode!()
  rescue
    _ -> nil
  end

  defp soak!(lab, seconds, evidence) do
    File.mkdir_p!(evidence)
    samples = Path.join(evidence, "soak-samples.jsonl")
    policy = Soak.policy()

    result = %{
      requested_seconds: seconds,
      stage: "capture_and_seal",
      performance: %{policy: policy, samples: Path.basename(samples)}
    }

    scenario("soak", result)

    {cfg, child} =
      client!(lab, "paired_exam", "soak", %{"seconds" => seconds})

    id = cfg["acquisition"]
    started = System.monotonic_time(:millisecond)
    viewer_stop = at(lab, "soak-viewer.stop")
    viewer_metrics = Path.join(evidence, "soak-preview.json")

    viewer =
      if lab.preview? do
        ready = at(lab, "soak-viewer.ready")

        process =
          launch!(lab, "soak-rtc-viewer", "node", [
            Path.join(@root, "ops/handheld/monitor_viewer.mjs"),
            at(lab, "server.json"),
            id,
            ready,
            viewer_stop,
            viewer_metrics,
            to_string(seconds),
            at(lab, "spool/" <> cfg["acquisition"])
          ])

        ProcessLab.wait!(
          fn -> File.regular?(ready) end,
          30_000,
          process,
          "soak actual RTP viewer"
        )

        process
      end

    IO.puts(
      "Soak started: #{seconds}s of capture. Rates and lag every #{div(Soak.interval_ms(), 1_000)}s."
    )

    {exit_status, failures} =
      File.open!(samples, [:write, :exclusive], fn file ->
        File.chmod!(samples, 0o600)

        try do
          await_soak!(lab, cfg, child, started, file)
        after
          assessment = Soak.observations(samples)
          timings = Soak.timings(lab.cfg["checkpoint_timings"])

          performance =
            Map.merge(result.performance, Map.put(assessment, :sampled_timings, timings))

          scenario("soak", %{result | performance: performance})
        end
      end)

    preview =
      if viewer do
        File.write!(viewer_stop, "capture complete\n", [:exclusive])
        ProcessLab.await_success!(viewer, 10_000)
        read(viewer_metrics)
      else
        %{"enabled" => false}
      end

    result = Map.put(report().scenarios["soak"], :preview, preview)
    performance = Map.put(result.performance, :failures, failures)
    result = Map.merge(result, %{performance: performance, client_exit: exit_status})
    scenario("soak", result)

    progress =
      sql!(lab, """
      SELECT json_build_object(
        'state', a.state, 'authority_state', s.authority_state, 'generation', s.generation,
        'streams', (SELECT json_object_agg(stream, json_build_object(
          'durable_sequence', receipt->>'durable_sequence',
          'durable_sample', receipt->>'durable_sample',
          'terminal', sealed_index->>'terminal',
          'checkpoints', receipt->>'journal_generation'))
        FROM (SELECT DISTINCT ON (stream) stream,receipt,sealed_index FROM stream_attempts
          WHERE acquisition_id=s.id ORDER BY stream,generation DESC) attempts))
      FROM acquisition_sessions s JOIN acquisitions a USING(id) WHERE s.id='#{id}'
      """)
      |> case do
        "" -> nil
        json -> JSON.decode!(json)
      end

    result =
      Map.merge(result, %{
        capture_and_seal_ms: System.monotonic_time(:millisecond) - started,
        progress: progress
      })

    spool_root = at(lab, "spool/" <> cfg["acquisition"])
    spool_result = read(Path.join(spool_root, "result.json"))

    source_records =
      Enum.reduce(~w(audio ecg), 0, fn name, total ->
        total + integer(read(Path.join([spool_root, name, "source.json"]))["sequence"])
      end)

    visits = spool_result["spool"]["reclamation_visits"]

    check!(
      is_integer(visits) and visits >= source_records and visits <= source_records * 2,
      "Spool reclaim work exceeded the linear source-record bound"
    )

    result =
      Map.put(result, :reclamation, %{
        visits: visits,
        source_records: source_records,
        max_visits: source_records * 2
      })

    measured_bounds!(lab)
    scenario("soak", result)
    check!(failures == [], "Soak exceeded its performance guardrail")
    check!(exit_status == 0, "Soak acquisition did not seal")

    check!(
      seconds < 20 or performance.sustained_lag_check_possible,
      "Soak ended without enough observations for the sustained lag check"
    )

    IO.puts("Soak capture sealed. Verifying stored bytes against the fixture.")
    {root, digest, manifest} = manifest!(lab, cfg)
    check!(manifest["defects"] == [], "Soak manifest includes defects")

    result =
      Map.merge(result, %{
        stage: "artifact_verification",
        manifest_digest: digest,
        manifest_bytes: File.stat!(Path.join(root, "manifest.mej1")).size
      })

    scenario("soak", result)
    started = System.monotonic_time(:millisecond)
    verified = Oracle.verify!(lab.dir, cfg, root, manifest)

    result =
      Map.merge(result, %{
        stage: "review",
        artifact_verification_ms: System.monotonic_time(:millisecond) - started,
        raw_payload_digests: verified.raw_payload_digests,
        oracle_payload_digests: verified.oracle_payload_digests,
        streams:
          Map.new(verified.coverage, fn {name, coverage} ->
            {name, %{samples: coverage.samples, segments: length(coverage.spans)}}
          end)
      })

    scenario("soak", result)
    started = System.monotonic_time(:millisecond)
    IO.puts("Soak byte verification passed. Checking Exam accepts the synthetic capture.")
    choice = review_choice(manifest, "baseline")
    check!(choice["decision"] == "complete", "Soak must reach complete review")
    action!(lab, id, "review", %{"digest" => digest, "choice" => choice})

    check!(
      count!(lab, "reviews", "acquisition_id='#{id}' AND manifest_digest='#{digest}'") == 1,
      "Soak review did not persist"
    )

    scenario(
      "soak",
      Map.merge(result, %{
        stage: "complete",
        review_ms: System.monotonic_time(:millisecond) - started
      })
    )

    lab
  end

  defp monitor_faults!(lab) do
    Enum.reduce(["stall", "kill", "startup", "stop"], lab, fn fault, current ->
      {next, _} =
        paired_case!(current, "local-monitor-" <> fault, %{
          "seconds" => if(fault == "stop", do: 30, else: 6),
          "local_monitor_fault" => fault
        })

      next
    end)
  end

  defp paired!(lab) do
    lab = monitor_faults!(lab)

    {lab, _} =
      paired_case!(lab, "baseline", %{
        "seconds" => 60,
        "trace_monitor" => true
      })

    {lab, _} = paired_case!(lab, "source-gap", %{"seconds" => 3, "gap" => true})
    {lab, _} = paired_case!(lab, "multi-sequence-gap", %{"seconds" => 3, "gap" => 3})
    {lab, _} = paired_case!(lab, "rational-s24", %{"seconds" => 3, "variant" => true})

    lab =
      Enum.reduce(@faults, lab, fn fault, lab ->
        {lab, _} = paired_case!(lab, hd(String.split(fault, ".")), %{"seconds" => 4}, fault)
        lab
      end)

    {lab, _} = paired_case!(lab, "spool-capacity", %{"seconds" => 4, "spool_limit" => 1200})
    network_denials!(lab)
    {lab, reset} = paired_case!(lab, "source-reset", %{"seconds" => 4, "reset" => true})
    check!(reset.coverage["ecg"].samples == 75, "ECG reset cutoff differs")
    paired_restart!(lab)

    measured_bounds!(lab)
    lab
  end

  defp measured_bounds!(lab) do
    observations = lab.cfg["checkpoint_timings"] |> File.stream!() |> Enum.map(&JSON.decode!/1)
    bounds = Enum.filter(observations, &(&1["stage"] == "bounds"))
    check!(bounds != [], "Missing actual frame and pending-credit measurements")

    [frame, payload, bytes, frames] =
      for key <- ~w(max_frame_bytes max_payload_bytes max_pending_bytes max_pending_frames) do
        bounds |> Enum.map(&Map.fetch!(&1["measurements"], key)) |> Enum.max()
      end

    spool =
      Path.wildcard(at(lab, "spool/*/result.json"))
      |> Enum.map(&read(&1)["spool"]["maximum"])
      |> Enum.max()

    metadata =
      sql!(
        lab,
        "SELECT coalesce(max((receipt->>'journal_generation')::integer),0) FROM stream_attempts"
      )
      |> integer()

    maxima = %{
      frame_bytes: payload,
      wire_frame_bytes: frame,
      pending_bytes: bytes,
      pending_frames: frames,
      spool_bytes: spool,
      metadata_records: metadata
    }

    bounded =
      Enum.all?(maxima, fn {key, value} -> value >= 0 and value <= Map.fetch!(@limits, key) end)

    record(%{measured_maxima: maxima, bounds_respected: bounded})
    check!(bounded, "Capture exceeded configured limits")
    lab
  end

  defp network_denials!(lab) do
    device = Enum.at(lab.cfg["devices"], 1)
    id = "negative-" <> Base.encode16(:crypto.strong_rand_bytes(5), case: :lower)

    cfg =
      Map.merge(lab.client, %{
        "acquisition" => id,
        "device" => device["id"],
        "encounter" => device["exam"],
        "wrong_encounter" => lab.client["encounter"],
        "credential_file" => device["credential_file"],
        "negative_result" => at(lab, "spool/#{id}/network-denials.json")
      })

    path = at(lab, "negative.json")
    save(path, cfg)

    child =
      isolate!(
        lab,
        "handheld",
        "mix",
        ["run", Path.join(@root, "apps/handheld/integration/network_denials.exs"), path],
        path
      )

    ProcessLab.await_success!(child, 60_000)
    result = read(cfg["negative_result"])

    check!(
      Enum.sort(result["checked"]) ==
        Enum.sort(
          ~w(wrong_encounter duplicate_json descriptor_mismatch competing_producer stale_generation swapped_number mismatched_epoch nonzero_epoch conflicting_replay)
        ),
      "Network denial coverage incomplete"
    )

    sql!(lab, "UPDATE device_credentials SET revoked=true WHERE device_id='secondary-gateway'")

    ProcessLab.wait!(
      fn ->
        count!(
          lab,
          "acquisition_manifests m JOIN acquisition_sessions s ON s.id=m.acquisition_id",
          "m.acquisition_id='#{id}' AND s.authority_state='expired' AND m.body->'defects' @> '[{\"code\":\"interrupted\"}]'::jsonb"
        ) == 1
      end,
      30_000,
      nil,
      "credential revocation"
    )

    scenario("network-denials", result)
  end

  defp paired_restart!(lab) do
    {cfg, child} = client!(lab, "paired_exam", "handheld-restart", %{"seconds" => 12})
    root = at(lab, "spool/#{cfg["acquisition"]}")
    names = ~w(audio ecg)

    ProcessLab.wait!(
      fn -> count!(lab, "stream_attempts", "acquisition_id='#{cfg["acquisition"]}'") == 2 end,
      30_000,
      child,
      "restart admission"
    )

    cutoffs =
      outage!(lab, fn ->
        ProcessLab.wait!(
          fn ->
            Enum.all?(names, fn name ->
              length(Path.wildcard(Path.join([root, name, "*.rec"]))) >= 3
            end)
          end,
          30_000,
          child,
          "offline spool"
        )

        duplicate = run_client!(lab, cfg, "paired_exam")

        check!(
          ProcessLab.await!(duplicate, 10_000) != 0 and
            log_contains?(duplicate, "spool already owned"),
          "Duplicate spool owner not refused"
        )

        ProcessLab.kill!(child)
        Map.new(names, &{&1, Oracle.restart_cutoff!(Path.join(root, &1))})
      end)

    resumed = run_client!(lab, cfg, "paired_exam")
    ProcessLab.await_success!(resumed, 45_000)
    {artifact, digest, manifest} = manifest!(lab, cfg)

    check!(
      Enum.all?(Map.values(manifest["streams"]), &(&1["index"]["terminal"] == "interrupted")),
      "Restart did not interrupt capture"
    )

    result = Oracle.verify!(lab.dir, Map.put(cfg, "restart_cutoffs", cutoffs), artifact, manifest)

    action!(lab, cfg["acquisition"], "review", %{
      "digest" => digest,
      "choice" => %{
        "decision" => "repeat",
        "note" => "Handheld restart interrupted capture",
        "metrics" => []
      }
    })

    append(:review_revisions, digest)

    scenario(
      "handheld-restart",
      Map.merge(result, %{
        manifest_digest: digest,
        synchronized_cutoffs: cutoffs,
        second_owner_refused: true
      })
    )
  end

  defp spot!(lab) do
    {cfg, child} =
      client!(lab, "plx_spot_check", "plx", %{
        "offline_finish" => true,
        "hold_after_ingestion" => true
      })

    root = at(lab, "spool/#{cfg["acquisition"]}")

    ProcessLab.wait!(
      fn -> File.regular?(Path.join(root, "inventory.json")) end,
      30_000,
      child,
      "Durable PLXS inventory"
    )

    inventory = read(Path.join(root, "inventory.json"))
    check!(length(inventory) == 2, "Expected two locally durable PLXS events")

    check!(
      count!(lab, "measurement_events", "acquisition_id='#{cfg["acquisition"]}'") == 0,
      "PLXS fixture reached the server before the offline-ingestion fault"
    )

    outage!(lab, fn -> ProcessLab.kill!(child) end)
    armed = barrier(lab, "measurement_commit.all")
    arm!(armed)
    resumed = run_client!(lab, cfg, "plx_spot_check")

    ProcessLab.wait!(
      fn -> File.regular?(reached(armed)) end,
      30_000,
      resumed,
      "Measurement committed before response"
    )

    check!(
      count!(lab, "measurement_events", "acquisition_id='#{cfg["acquisition"]}'") == 1,
      "Measurement commit barrier did not expose exactly one persisted event"
    )

    final =
      sql!(
        lab,
        "SELECT final_inventory->>'count',final_inventory->>'digest' FROM acquisition_sessions WHERE id='#{cfg["acquisition"]}'"
      )

    check!(
      final == "2|" <> sha(JSON.encode!(inventory)),
      "Early final inventory differs from the durable local inventory"
    )

    ProcessLab.kill!(lab.server)
    File.rm!(reached(armed))
    lab = lab |> start_server!() |> login!()
    ProcessLab.await_success!(resumed, 120_000)
    {_, digest, manifest} = manifest!(lab, cfg)
    [unusable, usable] = manifest["inventory"]

    check!(
      Enum.map(manifest["inventory"], fn row -> [row["event"]["event_id"], row["fingerprint"]] end) ==
        inventory,
      "PLXS final inventory differs from original local events"
    )

    check!(
      count!(lab, "measurement_events", "acquisition_id='#{cfg["acquisition"]}'") == 2,
      "PLXS replay created missing or duplicate events"
    )

    check!(
      unusable["event"]["metrics"]["spo2"] == ["missing", "nan"],
      "Unusable event unexpectedly eligible"
    )

    event = usable["event"]

    check!(
      %{"name" => "repeat_of", "origin" => "observed", "value" => unusable["event"]["event_id"]} in event[
        "provenance"
      ],
      "Missing PLXS repeat linkage"
    )

    %{
      "clock_id" => "unix_us",
      "boot_id" => "fixture",
      "ticks" => measured_at,
      "uncertainty_ticks" => "0"
    } =
      event["device_time"]

    measured_at = measured_at |> integer() |> DateTime.from_unix!(:microsecond)

    choice = %{
      "decision" => "accept_metrics",
      "metrics" => ["pulse_rate", "spo2"],
      "note" => "Synthetic acceptable completed event",
      "event_id" => event["event_id"]
    }

    id = cfg["acquisition"]

    action!(
      lab,
      id,
      "review",
      %{
        "digest" => digest,
        "choice" => Map.put(choice, "event_id", unusable["event"]["event_id"])
      },
      409
    )

    action!(lab, id, "review", %{"digest" => digest, "choice" => choice})
    action!(lab, id, "review", %{"digest" => digest, "choice" => choice})

    metrics =
      sql!(
        lab,
        "SELECT o.id FROM observations o JOIN reviews r ON r.id=o.decision_id WHERE r.acquisition_id='#{id}' ORDER BY o.id"
      )
      |> String.split("\n", trim: true)

    check!(length(Enum.uniq(metrics)) == 2, "Expected two distinct eligible native observations")
    Enum.each(metrics, &action!(lab, &1, "deliver"))

    remote =
      sql!(
        lab,
        "SELECT d.identifier_system,d.identifier_value,d.remote_ref FROM outbox_deliveries d JOIN observations o ON o.id=d.observation_id JOIN reviews r ON r.id=o.decision_id WHERE r.acquisition_id='#{id}' ORDER BY d.id"
      )
      |> String.split("\n", trim: true)

    check!(length(Enum.uniq(remote)) == 2, "Expected two distinct remote deliveries")
    base = hd(lab.cfg["encounters"])["destination"]

    observations =
      for row <- remote do
        [system, external, ref] = String.split(row, "|")
        check!(String.starts_with?(ref, "Observation/"), "Invalid remote observation reference")

        bundle =
          get!(
            base <>
              "/Observation?" <>
              URI.encode_query(%{"identifier" => system <> "|" <> external})
          )
          |> JSON.decode!()

        [resource] =
          for entry <- bundle["entry"] || [],
              get_in(entry, ["search", "mode"]) in [nil, "match"],
              do: entry["resource"]

        check!(
          match?({:ok, _, _}, DateTime.from_iso8601(resource["effectiveDateTime"])) and
            DateTime.compare(
              elem(DateTime.from_iso8601(resource["effectiveDateTime"]), 1),
              measured_at
            ) == :eq,
          "FHIR observation measurement time differs"
        )

        append(:fhir_external_ids, %{external: external, remote: ref})
        ref
      end

    check!(
      length(Enum.uniq(observations)) == 2,
      "Distinct metrics resolved to same remote observation"
    )

    run!(
      lab,
      "hapi-loss-readback",
      "mix",
      ["test", "integration"],
      Path.join(@root, "core/interop"),
      Map.put(lab.env, "FHIR_BASE_URL", base)
    )

    append(:review_revisions, digest)

    scenario("plx", %{
      event_ids: [unusable["event"]["event_id"], event["event_id"]],
      digest: digest,
      local_ingestion_before_ack: true,
      committed_event_replayed: true,
      early_final_inventory: true,
      actual_hapi_loss_readback: true
    })

    lab
  end

  defp browser!(lab) do
    run!(
      lab,
      "browser-capture",
      "mix",
      ["test", "integration"],
      Path.join(@root, "apps/exam"),
      Map.put(lab.env, "DATABASE_URL", lab.cfg["database_url"])
    )

    run!(lab, "browser-microphone", "node", [
      Path.join(@root, "ops/handheld/browser_capture.mjs"),
      at(lab, "server.json")
    ])

    scenario("browser-microphone", %{
      actual_browser_playback: true,
      encounter_scope: true,
      recording: true
    })

    lab
  end
end

MedFabric.HandheldAcceptance.main(System.argv())
