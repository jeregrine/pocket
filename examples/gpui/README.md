# Native GPUI counter

A desktop counter using `gpui_native` 0.2.0 from Hex. The entry point starts a
GPUI runtime and waits until the last window closes. Pocket's usual shutdown
then runs; no special "app mode" flag is needed.

## Run with Mix

```sh
cd examples/gpui
mix deps.get
MIX_ENV=prod mix run -e 'PocketGPUI.main(System.argv())'
```

Tests use GPUI's renderer-independent display, without opening a window:

```sh
mix test
```

## Build a single executable

You need Cargo/Rust, native platform build tools, and a **relinkable SDK**
exported from [`jeregrine/elixiraotc`](https://github.com/jeregrine/elixiraotc),
matching the pinned ERTS 17.0.6 and your machine's architecture. See that
repository's README for export instructions.

```sh
mix pocket.build --install --native-sdk /path/to/elixiraotc/native-sdk
./dist/pocket_gpui
```

Once the toolchain is cached, replace `--install` with `--offline`.
`--offline` only restricts Pocket's toolchain downloads, not Cargo or dependency
build scripts.

Pocket detects GPUI automatically, builds its Rust NIF as a static archive,
links it into BEAM, and uses that emulator for AOT recording and packaging.
No NIF shared library is shipped or extracted. **Copy only `dist/pocket_gpui`**
to another compatible machine to run it without Elixir, OTP, Cargo, or the SDK.
The adjacent manifest is an audit inventory, not a runtime dependency.

Review and commit all three locks: `mix.lock`, `pocket.lock`, and the generated
`pocket.gpui.lock`. The last file pins the Rust graph for the statically linked
artifact because GPUI's Hex package does not ship Cargo.lock. Ordinary Mix
compilation of GPUI's intermediate dynamic NIF still follows GPUI's own build
process; this is not a hermetic build.

### Native smoke test

This renders a real native frame, closes the window, and exits:

```sh
./dist/pocket_gpui --smoke
```

From Pocket's root, the integration test rebuilds the executable, copies only
that file to a fresh directory, removes build tools from `PATH`, and runs the
same native smoke test:

```sh
POCKET_TEST_NATIVE_SDK=/path/to/elixiraotc/native-sdk \
  mix test --include native test/native_integration_test.exs
```

It needs an interactive desktop session (or appropriate Linux display server).

## Current scope

- Validated locally on Apple silicon macOS, including native frame rendering
  through ERTS's original main thread. Other GPUI targets still need desktop
  integration validation.
- The GPUI adapter intentionally accepts only 0.2.0. Other NIF packages need
  their own static-build integration; arbitrary downloaded `.so` files cannot
  be converted to static archives.
- System libraries and graphics frameworks remain OS dependencies. "One file"
  does not mean a completely static OS-independent executable.
- `--native-sdk` is a **development bootstrap**, not the final installation
  experience. Reviewed SDK artifacts still need to be published and pinned in
  Pocket before SDK installation can be automatic. No linker flags or native
  packaging configuration are needed in the example's `mix.exs`.
- Non-native `priv/` files are embedded and readable through
  `:erl_prim_loader.get_file/1`. They are not real files for `File.open`,
  `File.read`, `dlopen`, or external executables. GPUI's renderer assets are
  linked into its native library.
