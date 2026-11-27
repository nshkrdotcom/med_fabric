Code.require_file("project_qc.exs", __DIR__)
Mix.start()

environment =
  case System.get_env("MIX_ENV", "dev") do
    "dev" -> :dev
    "test" -> :test
    "prod" -> :prod
    _ -> Mix.raise("Project QC requires dev, test or prod")
  end

Mix.env(environment)

# Load the real project and compile-time config. `mix run` would evaluate
# deployment runtime.exs before a setup/format/compile helper could execute.
Mix.Project.in_project(:workspace_qc, File.cwd!(), fn _ ->
  Mix.Task.run("loadconfig")

  case System.argv() do
    ["deps_get" | args] -> MedFabric.Build.ProjectQC.main_deps(args)
    args -> MedFabric.Build.ProjectQC.main(args)
  end
end)
