# Pocket BEAM

**Compile an Elixir CLI into one executable. Copy it to another compatible
machine and run it—no installed OTP, no release directory, no runtime extraction.**

Pocket is an experimental Mix frontend for
[Wojtek Mach's `elixiraotc`](https://github.com/wojtekmach/elixiraotc). It uses the
existing BEAM execution model and the backend's ahead-of-time code generation.
It is not a Rust runtime or an escript wrapper.

## Try it

You need Elixir 1.20+ to run the Mix frontend and `curl` for the initial toolchain
download. The application itself is compiled under the pinned toolchain, not
your host OTP.

```sh
cd examples/hello
mix pocket.build --install

./dist/hello
./dist/hello --version
printf 'hello from stdin\n' | ./dist/hello --echo
```

`--install` explicitly permits the first toolchain download. Alternatively,
install it separately with `mix pocket.toolchain`, then use `mix pocket.build`.
Subsequent builds reuse the verified cache.

The result is `dist/hello`, plus `dist/hello.manifest.json` for auditing. **Only
the executable is needed to run the program.** The manifest is a build inventory,
not a runtime dependency or a complete standards-compliant SBOM.

## Add it to a project

Pocket has not been published to Hex yet. For now, use a local path dependency:

```elixir
def project do
  [
    app: :my_tool,
    version: "0.1.0",
    pocket: [main: MyTool.CLI],
    deps: [{:pocket, path: "../pocket", runtime: false}]
  ]
end
```

The same interface is intended for a future Hex package. `runtime: false` matters:
the builder must not become a dependency of the executable.

```elixir
defmodule MyTool.CLI do
  def main(args) do
    IO.puts("Arguments: #{inspect(args)}")
    :ok
  end
end
```

```sh
mix deps.get
mix pocket.build --install
./dist/my_tool one two
```

Pocket never runs `deps.get` for you. Fetch and review dependencies separately,
then commit `mix.lock` and the generated **JSON** `pocket.lock`.

### Configuration

```elixir
pocket: [
  main: MyTool.CLI,       # required: module or {module, function, args}
  name: "my-tool",        # optional: defaults to the application name
  console: false,        # optional: include local IEx and diagnostics
  shutdown_timeout: 5_000 # optional: milliseconds, from 1 to 60_000
]
```

The module form calls `MyTool.CLI.main(argv)`. Alternatively, choose a function
and optional additional arguments:

```elixir
pocket: [main: {MyTool.CLI, :run, []}]
```

This calls `MyTool.CLI.run(argv)`. **Pocket always passes CLI arguments first**,
followed by the configured additional arguments. For example, to call
`MyTool.CLI.run(argv, "prefix", verbose: true)`:

```elixir
pocket: [main: {MyTool.CLI, :run, ["prefix", [verbose: true]]}]
```

The invocation is `apply(module, function, [argv | args])`, not a bare `apply/3`
of the configured tuple. CLI arguments are also available through `System.argv/0`.
Both forms use the same exit-status and cleanup contract.
The option is now named `main`, replacing the prototype's `main_module`.

```sh
mix pocket.build --output dist/my-tool
mix pocket.build --offline
```

`--offline` prohibits Pocket's toolchain downloads. It is **not a network sandbox**
for macros, dependency build scripts, or application code.

### Optional local console

For a long-running CLI, enable Pocket's built-in console:

```elixir
pocket: [main: MyTool.CLI, console: true]
```

No application-specific socket code or command dispatch is needed:

```sh
# Terminal 1: your normal long-running command
./dist/my_tool serve

# Terminal 2: attach to that application, not a second copy
./dist/my_tool --console
./dist/my_tool --status   # JSON: OS PID, applications, memory, process count
./dist/my_tool --observe  # one snapshot of the 15 largest processes by memory
./dist/my_tool --stop     # orderly OTP shutdown
```

The console is **real IEx in the service VM**: bindings, multiline expressions,
application calls, process inspection, and exceptions work. Ctrl-D/EOF detaches;
Ctrl-C terminates the client without stopping the service. `System.halt/0` or
`:init.stop/0` inside IEx, however, acts on the service itself.

The normal invocation opens a Unix-domain socket inside a new mode-0700 directory
at `<user-cache>/pocket/<executable-name>` (for example,
`~/Library/Caches/pocket/my_tool` on macOS). This is only an IPC endpoint, **not
runtime extraction**. No TCP port, epmd, BEAM distribution, installed Elixir,
or external client program is required.

One instance uses the default address. To run multiple instances, set
`POCKET_CONSOLE_DIR` to a different path for each. Clients accept the same
environment variable or an explicit directory: `my_tool --console /path/to/instance`.
Use a location under a trusted, user-owned parent directory. Socket paths must
fit within 103 bytes; use a shorter override if needed.

**Security and scope:**

- This enables arbitrary code execution as the service's OS user. Only enable
  it for applications where that is appropriate. Never use a privileged/setuid
  executable or an untrusted/shared parent directory.
- The directory must not already exist. Pocket refuses to overwrite a live or
  stale instance, including symlinks. Normal shutdown removes it; after a hard
  kill, verify the old process has exited before manually removing its socket
  and directory.
- These four leading command flags are reserved only in console-enabled builds.
  Attach commands do not start the user's applications or invoke the entry point.
- This first console has line-oriented input, not full terminal emulation:
  no tab completion or terminal job control. Global Logger/stderr stay with
  the service. Disconnecting is not a cancellation API for in-flight code.
- `--observe` is an observer-like process snapshot, not the wx Observer GUI
  or a continuously refreshing dashboard.
- IEx increases executable size. Default builds still exclude IEx and all
  console modules, reserve no management commands, and open no listener.
- The entry point must still stay alive: returning ends the process, just as
  in an ordinary Pocket CLI.

See [`examples/live`](examples/live/README.md) for a ticking, supervised worker
you can inspect, change, and restart through the console.

### CLI behavior

- CLI arguments are strings, passed as the first argument to either entry-point
  form and available through `System.argv/0`. Ordinary arguments are not VM flags.
- The project's runtime applications start before the entry point.
- Returning `:ok` exits successfully; `{:error, 1..255}` selects a nonzero exit.
- An uncaught exception produces a diagnostic on stderr and exits with status 1.
- Standard input works in pipes. Standard output/error use Unicode encoding.
- Returning ends the command even if it spawned background BEAM processes.
- Shutdown runs OTP application cleanup with a bounded deadline, including Logger
  shutdown. Cleanup may be cut short if it exceeds that deadline.
- Ctrl-C terminates the process instead of showing the Erlang BREAK menu.
- The CLI profile currently uses one normal BEAM scheduler and does not enable
  distribution. This is a deliberate small-CLI default, not a server profile.

## How a build works

1. Validate the project and `pocket.lock`.
2. Download if explicitly permitted, then verify the native toolchain's SHA-256.
3. Run a small build worker under that toolchain.
4. Compile the project and dependencies in production mode under
   `_build/pocket/<toolchain>/<target>`, separate from normal development builds.
5. Resolve the runtime application closure from OTP `.app` metadata.
6. Package its modules, consolidated protocols, compile-time application
   configuration, and a small CLI entry-point module.
7. Record AOT code and build the native executable with the embedded release.

The recording pass does not start the application or invoke the entry point. Compilation
still executes macros and build scripts, as ordinary Elixir compilation does.

Mix, Hex, and the Pocket builder are excluded from application executables.
IEx is also excluded unless `console: true` is explicitly configured.
The backend compiler contains build tools; the artifacts it produces here do not.
The first version trims **applications**, not individual modules or functions.

The bootstrap currently contains OTP 29 / ERTS 17.0.6 and Elixir 1.21.0-dev.
The exact upstream artifact and SHA-256 for each platform are pinned in
`priv/toolchain.json`; generated build manifests record the actual runtime versions.

## Toolchain ownership and updates

Pocket consumes toolchain releases; it does not maintain OTP patches or build OTP
in its normal CI. Source-build and release automation belong in `elixiraotc`.
Until a reviewed release is available, the bootstrap pins existing upstream
artifacts at an immutable Git commit.

`pocket.lock` must match the reviewed manifest compiled into this Pocket version.
An edited lock file cannot redirect downloads to an arbitrary server. Cached
toolchains are verified before execution and stored separately by toolchain ID.
Corrupt cache entries fail closed instead of being run or silently replaced.

When upgrading to a Pocket version with a new toolchain, review its manifest,
remove the old `pocket.lock`, and run `mix pocket.toolchain` to generate the new
lock and fetch the new toolchain. Commit the lock diff. Nothing follows a mutable
`latest` URL.

## Supported scope and security limits

This is a working prototype, **not a production-hardened runtime**.

- Native targets: macOS and Linux, ARM64 and x86-64. No cross-compilation or Windows.
- A single executable is not a promise of universal static linking. System-library
  and OS compatibility still matter; Linux bootstrap builds come from Ubuntu 24.04.
- Third-party `priv/` assets and native libraries are rejected, not extracted or
  silently dropped. Packaging custom NIFs and filesystem resources is future work.
- Only OTP applications available in the chosen toolchain can be used. The
  bootstrap is not a full OTP installation; missing runtime applications fail the build.
- `runtime.exs`, custom release definitions, and umbrella projects are rejected.
  Compile-time configuration is embedded; read runtime secrets from the environment
  in your application, not from build-time config.
- Dynamic dependency installation is unsupported. Dependencies must be in the
  build's application closure; no compatibility claim is made for runtime module
  discovery or arbitrary code loading.
- The upstream native launcher reserves **`-erlaot:*`** arguments, including
  recording and helper modes, before Elixir starts. Those arguments are not ordinary
  application arguments. Do not use these executables as privileged/setuid programs
  or expose their argument vector as an untrusted execution service.
- The experimental native archive loader has not been audited here. Hash pinning
  establishes artifact identity, not the safety of its code or its build provenance.
- Builds are not sandboxes. Untrusted projects and dependencies need isolated,
  unprivileged build environments without secrets.
- Bundled runtime vulnerabilities require rebuilding and redistributing your CLI.
- `dist/*.manifest.json` inventories application versions, packaged paths, and
  artifact/toolchain digests. It is not a complete license, transitive native-library,
  vulnerability, or source-provenance report.

## Development

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test

# Explicitly install the example's toolchain before offline integration tests.
(cd examples/hello && mix pocket.toolchain)
mix test --include integration
```

Integration tests copy just the executable to a fresh directory and check
production configuration, startup/shutdown callbacks, stdin/stdout/stderr,
exit codes, Ctrl-C, Unicode arguments, bounded cleanup, background processes,
and absence of runtime extraction or bundled Mix/Hex. Console tests also build
the live example (reusing the hello example's verified toolchain cache), attach
from a second executable, exercise IEx state and Unicode, verify that clients
do not start application callbacks, and check private socket lifecycle.
