defmodule MedFabric.Store.Postgres do
  @moduledoc "Native PostgreSQL connection and schema setup."

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    {url, opts} = Keyword.pop!(opts, :url)
    uri = URI.new!(url)

    unless uri.scheme in ["postgres", "postgresql"] and is_binary(uri.path) and
             byte_size(uri.path) > 1,
           do: raise(ArgumentError, "Expected a PostgreSQL database URL")

    auth = credentials(uri.userinfo)
    connection = Enum.map(URI.decode_query(uri.query || ""), &connection_option/1)
    location = if connection[:socket_dir], do: [], else: [hostname: uri.host || "localhost"]

    Postgrex.start_link(
      [database: URI.decode(String.trim_leading(uri.path, "/")), port: uri.port || 5432] ++
        location ++ auth ++ connection ++ opts
    )
  end

  defp credentials(nil), do: []

  defp credentials(info) do
    case String.split(info, ":", parts: 2) do
      [user] -> [username: URI.decode(user)]
      [user, pw] -> [username: URI.decode(user), password: URI.decode(pw)]
    end
  end

  defp connection_option({"host", "/" <> _ = path}), do: {:socket_dir, path}
  defp connection_option({"sslmode", "disable"}), do: {:ssl, false}

  defp connection_option({"sslmode", "verify-full"}),
    do: {:ssl, [verify: :verify_peer, cacerts: :public_key.cacerts_get()]}

  defp connection_option({key, _}),
    do: raise(ArgumentError, "Unsupported PostgreSQL URL option #{key}")

  def migrate(db \\ __MODULE__) do
    scripts =
      Application.app_dir(Application.get_application(__MODULE__), "priv/sql/*.sql")
      |> Path.wildcard()
      |> Enum.sort()

    Postgrex.transaction(db, fn conn ->
      Postgrex.query!(conn, "SELECT pg_advisory_xact_lock(73160649)", [])

      scripts
      |> Enum.flat_map(fn path -> path |> File.read!() |> String.split(";") end)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.each(&Postgrex.query!(conn, &1, []))
    end)
  end
end
