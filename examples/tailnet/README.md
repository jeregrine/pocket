# Remote into an application over Tailscale

A small supervised counter with authenticated `status`, `add`, and optional
remote IEx. The client controls the **existing application**, not another copy.
There is no SSH daemon, EPMD, shared BEAM cookie, or BEAM distribution.

**One executable, acting as server or client.** Pocket statically links the
real `tailscale` 0.6.1 Rust NIF into BEAM, then records AOT code against that
emulator. No shared NIF, runtime extraction, Mix, or installed OTP is needed
on the destination. System libraries remain OS dependencies.

## Build

Building requires Elixir 1.20+, OTP 29, Rust/Cargo, and native build tools. Rust 1.96.1
works with the pinned dependency. The first build compiles a sizeable Rust
dependency tree. Use a platform supported by `tailscale-rs`: Linux x86-64/ARM64
or macOS ARM64 for this demo. The permission checks and shell recipes assume Unix.

```sh
cd examples/tailnet
mix deps.get
mix pocket.build --install --native-sdk /path/to/elixiraotc/native-sdk
./dist/tailnet-demo --smoke
```

The SDK must match the pinned ERTS 17.0.6 and architecture. Export it using the
native-SDK tooling in [jeregrine/elixiraotc](https://github.com/jeregrine/elixiraotc);
this is the same development bootstrap as the GPUI example. SDKs are not yet
automatically downloaded. After the toolchain is cached, use `--offline` instead
of `--install`; this does not disable Cargo's network access.

Copy **only `dist/tailnet-demo`** to another compatible machine. The adjacent
manifest records the static NIF and its SDK/archive/lock digests but is not a
runtime dependency. Commit `mix.lock`, `pocket.lock`, and `pocket.tailscale.lock`.

The application has no automatically started server: `tailnet-demo status` and
`tailnet-demo console` cannot accidentally create a second counter/listener.
It uses `console: :embedded` to include real IEx and Pocket's shared session
without opening Pocket's automatic local Unix socket.

## Try locally without a tailnet

Run this in a Bash-compatible terminal. It generates an ephemeral token in your
environment, not in a source file or command-line argument:

```sh
export POCKET_DEMO_TOKEN="$(openssl rand -hex 32)"
./dist/tailnet-demo serve --local --allow-console &
server_pid=$!

# Wait for "Listening on 127.0.0.1:4141".
./dist/tailnet-demo status --local
./dist/tailnet-demo add 7 --local
./dist/tailnet-demo console --local
```

At the real IEx prompt:

```elixir
TailnetDemo.Counter.status()
TailnetDemo.Counter.add(100)
x = 41
x + 1
Supervisor.which_children(TailnetDemo.Sessions)
```

Type `.quit` or send EOF to detach. The counter keeps running:

```sh
./dist/tailnet-demo status --local
kill -TERM "$server_pid"
unset POCKET_DEMO_TOKEN
```

Loopback mode binds only `127.0.0.1` and refuses non-loopback destinations.
It has authentication but no transport encryption; it is for local development,
not a substitute for the tailnet transport.

## Try across two machines

Build for the destination's platform, then copy the executable to both machines
(use separate native builds when platforms differ). Supply secrets through your password manager
or an interactive terminal, not through `mix.exs`, a committed `.env`, or chat:

- `POCKET_DEMO_TOKEN`: the same randomly generated 32–1024-byte operator secret
  on both machines. Possessing it authorizes all demo commands.
- `TS_AUTHKEY`: a suitably scoped Tailscale enrollment key for each new device.
  It is normally only needed on the first connection; subsequent invocations
  reuse the saved private device identity.

Restrict tailnet grants/ACLs so only intended operators can reach the server's
TCP port 4141. This application token is an additional check, not a replacement
for tailnet authorization. Do not run the demo as root or expose it to untrusted
end users.

On the server:

```sh
./tailnet-demo serve --allow-console --hostname pocket-demo-server
```

It prints its tailnet IP and port. On the client, use that IP instead of the
illustrative address below:

```sh
./tailnet-demo status --peer 100.64.0.10
./tailnet-demo add 7 --peer 100.64.0.10
./tailnet-demo console --peer 100.64.0.10
```

No host-wide Tailscale daemon is used: the Rust library owns the tailnet sockets.
Use IP addresses here; this demo does not depend on MagicDNS.
Omit `--allow-console` to allow only the structured commands, not arbitrary IEx.

### Identity and state

Identity keys live outside the executable/repository, under the OS's per-user
data directory, with separate `server` and `client` directories. On Linux this
is normally `~/.local/share/pocket-tailnet-demo/`. The directory is private
(`0700`) and the key file is checked/restricted to `0600`.

Override it with `--state-dir /private/path`. The directory must not be a symlink
or accessible to other users. Choose a path under directories you own.
**Concurrent processes need distinct identity directories**—do not share one
live Tailscale identity between multiple clients. Sequential client commands
can reuse the default identity. `--hostname` controls the requested device name.

The counter itself is deliberately in-memory. A worker restart resets it;
supervision is not durable storage.

## Architecture

```text
client command / terminal
    → Tailscale TCP (or explicit loopback test transport)
    → bounded JSON frames + operator authentication
    → status/add: the existing supervised Counter
    → console: Pocket.Console.Session → real IEx in the server
```

The transport adapter hook on `Pocket.Console.Session` reuses the local console's
IO implementation. Local Unix-socket sessions still use the same default path.
Remote clients send JSON and input text, never serialized Erlang terms or
executable IO protocol requests. IEx parsing/evaluation remains server-side.

## Limits and security boundaries

- **Remote IEx is arbitrary code execution with the server's privileges.**
  This is an operator demo, not a sandbox or a production management service.
- Console access is opt-in. The demo deliberately has no remote shutdown command.
- Frames are capped at 64 KiB, with at most two concurrent sessions. Authentication
  has a five-second deadline; authorized sessions have a five-minute lifetime.
  Reconnect for a new session. Console output exceeding the frame limit is not supported.
- `tailscale` 0.6.1 uses blocking dirty-I/O NIFs and exposes no explicit stream
  close/cancellation operation. Dropping resources is not guaranteed to interrupt
  an in-flight native read. The Elixir deadlines do **not** guarantee native I/O
  cancellation. This must be addressed before treating the service as hardened.
- The console is line-oriented, not a PTY: no tab completion or terminal job
  control. Global Logger/stderr remain on the server. Detach is not a rollback
  or reliable cancellation mechanism for arbitrary code you started in IEx.
- The transport library is experimental, including key-lifecycle and NAT traversal
  limitations. No automatic key rotation is implemented by this demo.
- The static artifact's Rust graph is pinned in `pocket.tailscale.lock`. The
  intermediate dynamic NIF still follows Rustler's build process, and native
  compilers/SDKs are local build inputs: this is not a hermetic build.
- The adapter accepts only Tailscale 0.6.1. Combining it with another independent
  Rustler static NIF, such as GPUI, is not supported yet.
- The loopback tests do not prove NAT traversal, real tailnet enrollment, or a
  two-machine connection. Those require the operator-provided credentials and
  tailnet policy described above.

## Checks

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

These compile/load the real Rust binding and exercise the same session protocol
over loopback: authentication, command routing, real IEx bindings and multiline
input, clean detach, disabled-console policy, framing, and identity permissions.
They do not join a tailnet or require credentials.

To verify the deployable artifact from Pocket's root:

```sh
POCKET_TEST_NATIVE_SDK=/path/to/elixiraotc/native-sdk \
  mix test --include native test/tailnet_native_integration_test.exs
```

This builds the binary, copies only that file to a fresh directory, removes build
tools from `PATH`, calls the statically linked NIF, and exercises server/client
commands plus remote IEx over loopback. It asserts that no payload is extracted
and no automatic local-console socket is created. The real two-machine tailnet
path still needs the enrollment credentials and grants described above.
