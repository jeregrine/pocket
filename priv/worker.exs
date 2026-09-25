# Run by the verified elixiraotc, not by the user's host Elixir.
# The backend compiles this tiny bootstrap; the Mix project is compiled inside
# that runtime, including its dependencies and consolidated protocols.
Code.require_file(System.fetch_env!("POCKET_COMPILER_SOURCE"))
apply(Pocket.Compiler, :prepare!, [System.fetch_env!("MIX_BUILD_PATH")])
:code.delete(Pocket.Compiler)
:code.purge(Pocket.Compiler)
# Mix.State captures builtin application paths when Mix starts.
Mix.start()
Mix.env(:prod)
Application.load(:sasl)
Mix.CLI.main(["pocket.assemble"])
