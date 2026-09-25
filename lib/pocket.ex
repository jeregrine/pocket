defmodule Pocket do
  @moduledoc """
  Build a Mix project as a single native executable.

  Configure `pocket: [main: MyApp.CLI]` or
  `pocket: [main: {MyApp.CLI, :run, []}]` in `mix.exs`, then run
  `mix pocket.build`. A module receives CLI arguments through `main/1`; an MFA
  receives CLI arguments first, followed by its configured additional arguments.
  Both return `:ok` or `{:error, status}`. See `mix help pocket.build`.

  Pocket currently uses an experimental, pinned OTP AOT backend. It is not
  a sandbox or a production-hardened replacement for upstream OTP.
  """
end
