defmodule MedFabric.HandheldDemo do
  @moduledoc false
  @loopback {127, 0, 0, 1}
  @socket_options [
    :binary,
    active: false,
    nodelay: true,
    send_timeout: 1_000,
    send_timeout_close: true
  ]

  def main(args) do
    case OptionParser.parse(args, strict: [run_dir: :string]) do
      {opts, ["prepare"], []} -> prepare!(run_dir(opts))
      {[run_dir: path], ["relay"], []} -> relay!(Path.expand(path))
      _ -> raise "Usage: elixir ops/handheld_demo.exs prepare|relay --run-dir DIR"
    end
  end

  defp run_dir(opts) do
    Path.expand(opts[:run_dir] || Path.join(System.tmp_dir!(), "med-fabric-demo-#{token(9)}"))
  end

  def prepare!(directory) do
    case File.lstat(directory) do
      {:error, :enoent} -> File.mkdir_p!(directory)
      {:ok, %{type: :directory}} -> :ok
      _ -> raise "Unsafe demo directory"
    end

    unless File.ls!(directory) == [], do: raise("Choose a new empty demo directory")
    File.chmod!(directory, 0o700)

    for name <- ~w(artifact spool barriers logs pghost oracle) do
      path = Path.join(directory, name)
      File.mkdir!(path)
      File.chmod!(path, 0o700)
    end

    [http, tls, proxy, postgres, preview, fhir] = available_ports!(6)
    {ca, cert, key} = certificates!(directory)
    device_credential = private_file!(directory, "device.credential", token(48))
    secondary_credential = private_file!(directory, "secondary.credential", token(48))
    preview_credential = private_file!(directory, "preview.credential", token(48))
    password = token(48)
    private_file!(directory, "postgres.credential", password)

    tag = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    exam = "fixture-#{tag}"
    device = "reference-gateway"

    encounter = %{
      exam: exam,
      patient_actor: "synthetic-patient",
      clinician_actor: "synthetic-reviewer",
      patient_key: token(40),
      clinician_key: token(40),
      patient_ref: "Patient/#{exam}",
      encounter_ref: "Encounter/#{exam}",
      destination: System.get_env("FHIR_BASE_URL", "http://127.0.0.1:#{fhir}/fhir")
    }

    second_exam = "secondary-#{tag}"

    secondary = %{
      encounter
      | exam: second_exam,
        patient_key: token(40),
        clinician_key: token(40),
        patient_ref: "Patient/#{second_exam}",
        encounter_ref: "Encounter/#{second_exam}"
    }

    server = %{
      deployment_uuid: deployment_uuid(),
      http_port: http,
      tls_port: tls,
      proxy_port: proxy,
      postgres_port: postgres,
      preview_port: preview,
      database_url: "postgres://lab:#{password}@127.0.0.1:#{postgres}/postgres",
      cookie_secret: token(64),
      artifact_dir: Path.join(directory, "artifact"),
      barrier_dir: Path.join(directory, "barriers"),
      cert: cert,
      key: key,
      encounters: [encounter, secondary],
      preview_url: nil,
      preview_credential_file: preview_credential,
      authorize_scenarios: true,
      devices: [
        %{id: device, credential_file: device_credential, exam: exam},
        %{id: "secondary-gateway", credential_file: secondary_credential, exam: second_exam}
      ]
    }

    handheld = %{
      server: "wss://localhost:#{proxy}",
      ca_file: ca,
      credential_file: device_credential,
      device: device,
      encounter: exam,
      acquisition: "paired-#{exam}",
      seed: 37,
      seconds: 60,
      spool_root: Path.join(directory, "spool"),
      spool_limit: 67_108_864,
      preview: false
    }

    # Synthetic roles run on the same host clock. The bounded clock assumption
    # is explicit in the sidecar config and retained with qualification evidence.
    private_file!(
      directory,
      "preview.json",
      JSON.encode_to_iodata!(%{
        port: preview,
        credential_file: preview_credential,
        trusted_clock: true,
        clock_error_ms: 100,
        max_peers: 8,
        max_source_peers: 2,
        ice_servers: [],
        ice_transport_policy: "all"
      })
    )

    private_file!(directory, "server.json", JSON.encode_to_iodata!(server))
    private_file!(directory, "handheld-a.json", JSON.encode_to_iodata!(handheld))
    IO.puts("Prepared synthetic lab at #{directory}")
    {server, handheld}
  end

  defp available_ports!(count) do
    sockets =
      for _ <- 1..count do
        {:ok, socket} = :gen_tcp.listen(0, ip: @loopback, active: false)
        socket
      end

    try do
      for socket <- sockets do
        {:ok, {@loopback, port}} = :inet.sockname(socket)
        port
      end
    after
      Enum.each(sockets, &:gen_tcp.close/1)
    end
  end

  defp deployment_uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    <<first::binary-size(8), second::binary-size(4), third::binary-size(4),
      fourth::binary-size(4), fifth::binary-size(12)>> =
      Base.encode16(<<a::32, b::16, 4::4, c::12, 2::2, d::14, e::48>>, case: :lower)

    Enum.join([first, second, third, fourth, fifth], "-")
  end

  defp certificates!(directory) do
    ca_key = Path.join(directory, "temporary-ca.key")
    ca = Path.join(directory, "ca.pem")
    cert = Path.join(directory, "cert.pem")
    key = Path.join(directory, "key.pem")
    common = ~w(req -x509 -newkey rsa:2048 -nodes -days 2)

    try do
      openssl!(
        common ++
          [
            "-subj",
            "/CN=MedFabric synthetic lab CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-keyout",
            ca_key,
            "-out",
            ca
          ]
      )

      openssl!(
        common ++
          [
            "-CA",
            ca,
            "-CAkey",
            ca_key,
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-addext",
            "basicConstraints=critical,CA:FALSE",
            "-addext",
            "extendedKeyUsage=serverAuth",
            "-keyout",
            key,
            "-out",
            cert
          ]
      )

      File.chmod!(key, 0o600)
      {ca, cert, key}
    after
      File.rm(ca_key)
    end
  end

  defp openssl!(args) do
    case System.cmd("openssl", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "OpenSSL exited #{status}: #{output}"
    end
  end

  defp private_file!(directory, name, bytes) do
    path = Path.join(directory, name)
    File.write!(path, bytes, [:exclusive])
    File.chmod!(path, 0o600)
    path
  end

  def token(size), do: size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # Keep the transport encrypted end to end. The outage flag closes existing
  # TCP sessions and rejects new ones while present.
  def relay!(directory) do
    config = directory |> Path.join("server.json") |> File.read!() |> JSON.decode!()
    %{"tls_port" => upstream, "proxy_port" => listen} = config
    outage = Path.join(directory, "outage")

    case :gen_tcp.listen(listen, @socket_options ++ [ip: @loopback, reuseaddr: true]) do
      {:ok, server} ->
        IO.puts("TLS relay ready on 127.0.0.1:#{listen}")
        accept_clients(server, upstream, outage)

      {:error, reason} ->
        IO.puts(:stderr, "error: TLS relay cannot listen on 127.0.0.1:#{listen}: #{reason}")
        System.halt(1)
    end
  end

  defp accept_clients(server, upstream, outage) do
    {:ok, client} = :gen_tcp.accept(server)

    {:ok, worker} =
      Task.start(fn ->
        receive do
          {:client, socket} -> relay_client(socket, upstream, outage)
        after
          1_000 -> :ok
        end
      end)

    case :gen_tcp.controlling_process(client, worker) do
      :ok -> send(worker, {:client, client})
      {:error, _} -> :gen_tcp.close(client)
    end

    accept_clients(server, upstream, outage)
  end

  defp relay_client(client, upstream, outage) do
    with false <- File.exists?(outage),
         {:ok, server} <- :gen_tcp.connect(@loopback, upstream, @socket_options, 1_000) do
      try do
        :ok = :inet.setopts(client, active: :once)
        :ok = :inet.setopts(server, active: :once)
        Process.send_after(self(), :outage_check, 25)
        relay_packets(client, server, outage)
      after
        :gen_tcp.close(server)
      end
    end
  after
    :gen_tcp.close(client)
  end

  defp relay_packets(client, server, outage) do
    receive do
      {:tcp, source, bytes} when source == client or source == server ->
        target = if source == client, do: server, else: client

        with :ok <- :gen_tcp.send(target, bytes),
             :ok <- :inet.setopts(source, active: :once) do
          relay_packets(client, server, outage)
        end

      :outage_check ->
        unless File.exists?(outage) do
          Process.send_after(self(), :outage_check, 25)
          relay_packets(client, server, outage)
        end

      {:tcp_closed, _socket} ->
        :ok

      {:tcp_error, _socket, _reason} ->
        :ok
    end
  end
end
