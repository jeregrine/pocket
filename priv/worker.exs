# Run by the verified elixiraotc, not by the user's host Elixir.
# The backend compiles this tiny bootstrap; the Mix project is compiled inside
# that runtime, including its dependencies and consolidated protocols.
Mix.start()
Mix.env(:prod)
Application.load(:sasl)
Mix.CLI.main(["pocket.assemble"])
