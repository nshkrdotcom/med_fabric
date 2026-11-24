defmodule MedFabric.MixProject do
  use Mix.Project

  def project do
    [
      app: :med_fabric,
      version: "0.1.0",
      build_path: "_build",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      erlc_paths: [],
      deps: deps(),
      description: "Reusable clinical encounter workflow libraries for Med Fabric",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def elixirc_paths(:test) do
    if File.dir?("test/support") do
      ["lib", "test/support"]
    else
      ["lib"]
    end
  end

  def elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:postgrex, "~> 0.23"},
      {:req, "~> 0.7.5"},
      {:credo, "~> 1.7", [only: [:dev, :test], runtime: false]},
      {:dialyxir, "~> 1.4", [only: [:dev, :test], runtime: false]},
      {:ex_doc, "~> 0.40", [only: :dev, runtime: false]}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: [],
      links: %{"GitHub" => "https://github.com/nshkrdotcom/med_fabric"},
      files: [
        ".formatter.exs",
        "CHANGELOG.md",
        "LICENSE",
        "README.md",
        "assets/med_fabric.svg",
        "config",
        "docs",
        "lib",
        "mix.exs",
        "priv",
        "projection.lock.json"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["CHANGELOG.md", "LICENSE", "README.md", "docs/architecture/browser-to-record.md"]
    ]
  end
end
