Code.require_file("support/native_fhir.exs", __DIR__)

defmodule MedFabric.Interop.HAPILostReplyProxy do
  @moduledoc false
  @limit 1_048_576

  # Test-only, single-request TCP proxy. It forwards a real request to a local
  # HTTP HAPI endpoint and closes the client only after consuming HAPI's reply.
  def start(url, owner) do
    %URI{scheme: "http", host: host, port: port, userinfo: nil} = URI.parse(url)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, local_port}} = :inet.sockname(listener)

    {:ok, pid} =
      Task.start_link(fn ->
        result = forward(listener, host, port)
        send(owner, {:hapi_reply_discarded, result})
      end)

    {pid, listener, local_port}
  end

  defp forward(listener, host, port) do
    {address, family} =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} when tuple_size(ip) == 8 -> {ip, [:inet6]}
        {:ok, ip} -> {ip, []}
        _ -> {String.to_charlist(host), []}
      end

    authority = if family == [:inet6], do: "[#{host}]:#{port}", else: "#{host}:#{port}"

    with {:ok, front} <- :gen_tcp.accept(listener, 10_000) do
      try do
        with {:ok, header, rest} <- headers(front, <<>>),
             [_, length] <-
               Regex.run(~r/\r\ncontent-length:\s*([0-9]+)\r\n/i, "\r\n" <> header <> "\r\n"),
             size = String.to_integer(length),
             true <- size <= @limit,
             {:ok, body} <- body(front, rest, size),
             {:ok, back} <-
               :gen_tcp.connect(
                 address,
                 port,
                 family ++ [:binary, active: false, packet: :raw],
                 5_000
               ) do
          try do
            [request | fields] = String.split(header, "\r\n")

            fields =
              Enum.reject(fields, fn field ->
                String.starts_with?(String.downcase(field), ["host:", "connection:"])
              end)

            rewritten =
              Enum.join(
                [request | fields] ++ ["host: " <> authority, "connection: close"],
                "\r\n"
              )

            with :ok <- :gen_tcp.send(back, [rewritten, "\r\n\r\n", body]),
                 {:ok, response} <- response(back, <<>>),
                 true <- Regex.match?(~r/\AHTTP\/1\.[01] 20[01] /, response) do
              :ok
            else
              error -> {:upstream_failed, error}
            end
          after
            :gen_tcp.close(back)
          end
        else
          error -> {:proxy_failed, error}
        end
      after
        :gen_tcp.close(front)
      end
    end
  end

  defp headers(socket, data) when byte_size(data) <= 16_384 do
    case :binary.split(data, "\r\n\r\n") do
      [header, rest] ->
        {:ok, header, rest}

      [_] ->
        with {:ok, bytes} <- :gen_tcp.recv(socket, 0, 5_000), do: headers(socket, data <> bytes)
    end
  end

  defp headers(_, _), do: {:error, :header_limit}
  defp body(_socket, data, size) when byte_size(data) == size, do: {:ok, data}

  defp body(socket, data, size) when byte_size(data) < size do
    with {:ok, bytes} <- :gen_tcp.recv(socket, size - byte_size(data), 5_000),
         do: {:ok, data <> bytes}
  end

  defp body(_, _, _), do: {:error, :unexpected_extra_request_bytes}

  defp response(socket, data) when byte_size(data) <= @limit do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> response(socket, data <> bytes)
      {:error, :closed} when byte_size(data) > 0 -> {:ok, data}
      error -> error
    end
  end

  defp response(_, _), do: {:error, :response_limit}
end

defmodule MedFabric.Interop.DeviceFHIRIntegrationTest do
  use ExUnit.Case, async: false
  alias MedFabric.Interop.{FhirClient, HAPILostReplyProxy, NativeFHIRFixture}
  @moduletag timeout: 60_000

  setup do
    ctx = NativeFHIRFixture.create!()
    %URI{scheme: "http", host: host} = URI.parse(ctx.url)

    assert host in ["localhost", "127.0.0.1", "::1"],
           "TCP response-loss proof requires the isolated local HAPI lab"

    on_exit(fn -> NativeFHIRFixture.cleanup(ctx) end)
    %{fixture: ctx}
  end

  test "actual dropped response retains exact decimal and event provenance", %{fixture: ctx} do
    native =
      NativeFHIRFixture.native(ctx, "device_spo2_v1", %{"mantissa" => "972", "exponent" => "-1"})

    assert {:ok, resource} = FhirClient.resource_checked(native, ctx.identifier, ctx.refs)
    {pid, listener, port} = HAPILostReplyProxy.start(ctx.url, self())

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    end)

    path = URI.parse(ctx.url).path || ""

    assert {:unknown, :possible_remote_effect} =
             FhirClient.deliver(resource,
               base_url: "http://127.0.0.1:#{port}" <> path,
               receive_timeout: 15_000
             )

    assert_receive {:hapi_reply_discarded, :ok}, 15_000

    [remote] = NativeFHIRFixture.observations(ctx)
    reference = "Observation/" <> remote["id"]
    assert Decimal.equal?(remote["valueQuantity"]["value"], Decimal.new("97.2"))
    assert remote["valueQuantity"]["code"] == "%"

    assert remote["device"]["identifier"] == %{
             "system" => "urn:medfabric:source-device",
             "value" => ctx.prefix
           }

    assert remote["effectiveDateTime"] == native["effective_at"]
    assert remote["issued"] == native["issued"]
    assert remote["derivedFrom"] == resource["derivedFrom"]
    assert remote["meta"]["profile"] == resource["meta"]["profile"]
    assert {:matched, ^reference} = FhirClient.reconcile(resource, base_url: ctx.url)
    assert {:matched, ^reference} = FhirClient.deliver(resource, base_url: ctx.url)
    assert [_] = NativeFHIRFixture.observations(ctx)

    for changed <- [
          put_in(resource, ["valueQuantity", "code"], "1"),
          put_in(resource, ["device", "identifier", "value"], "wrong-device"),
          Map.put(resource, "derivedFrom", [])
        ] do
      assert {:conflict, :conflicting_remote_record} =
               FhirClient.reconcile(changed, base_url: ctx.url)
    end
  end
end
