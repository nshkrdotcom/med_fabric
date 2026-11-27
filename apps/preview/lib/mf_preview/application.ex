defmodule MedFabric.Preview.Application do
  @moduledoc "Supervises bounded disposable media peers behind an authenticated loopback listener."
  use Application

  def start(_, _) do
    with {:ok, config} <- validate_config(Application.get_env(:mf_preview, :listen)) do
      Supervisor.start_link([
        {Registry, keys: :unique, name: MedFabric.Preview.Registry},
        {MedFabric.Preview.Feed, config},
        {DynamicSupervisor, strategy: :one_for_one, name: MedFabric.Preview.Peers, max_children: config[:max_peers]},
        {Bandit, plug: {MedFabric.Preview.Endpoint, config}, ip: {127, 0, 0, 1}, port: config[:port]}
      ], strategy: :rest_for_one, name: MedFabric.Preview.Supervisor)
    end
  end

  def validate_config(config) when is_list(config) do
    allowed = [:port, :secret, :clock_error_ms, :trusted_clock, :max_peers, :max_source_peers, :ice_servers, :ice_transport_policy]
    if Keyword.keyword?(config) and length(Keyword.keys(config)) == length(Enum.uniq(Keyword.keys(config))) do
      values = Keyword.merge([clock_error_ms: 2_000, trusted_clock: false, max_peers: 32, max_source_peers: 4, ice_servers: [], ice_transport_policy: :all], config)
    valid = Keyword.keyword?(config) and Enum.all?(Keyword.keys(config), &(&1 in allowed)) and
      is_integer(values[:port]) and values[:port] in 0..65535 and is_binary(values[:secret]) and
      byte_size(values[:secret]) in 32..4096 and values[:trusted_clock] == true and
      is_integer(values[:clock_error_ms]) and values[:clock_error_ms] in 0..2000 and
      is_integer(values[:max_peers]) and values[:max_peers] in 1..128 and
      is_integer(values[:max_source_peers]) and values[:max_source_peers] in 1..16 and
      values[:max_source_peers] <= values[:max_peers] and
      values[:ice_transport_policy] in [:all, :relay] and is_list(values[:ice_servers]) and
      length(values[:ice_servers]) <= 8
      if valid and MedEx.RTC.Provider.validate_options(owner: self(), ice_servers: values[:ice_servers], ice_transport_policy: values[:ice_transport_policy]) == :ok,
        do: {:ok, values}, else: {:error, :invalid_preview_configuration}
    else
      {:error, :invalid_preview_configuration}
    end
  end
  def validate_config(_), do: {:error, :invalid_preview_configuration}
end
