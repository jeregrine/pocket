defmodule Pocket do
  @moduledoc """
  Build a Mix project as a single native executable.

  Configure `pocket: [main_module: MyApp.CLI]` in `mix.exs`, then run
  `mix pocket.build`. The entry point implements `main/1`, returning `:ok`
  or `{:error, status}`. See `mix help pocket.build` for the build contract.

  Pocket currently uses an experimental, pinned OTP AOT backend. It is not
  a sandbox or a production-hardened replacement for upstream OTP.
  """
end
