# Live console example

A long-running, single-executable app with a supervised counter that ticks once
per second. All console transport and management commands are supplied by Pocket;
the example only opts into `console: true` in `mix.exs`.

## Build and run

```sh
cd examples/live
mix pocket.build --install

# Terminal 1
./dist/pocket-live serve

# Terminal 2, from the same directory
./dist/pocket-live --console
```

No installed OTP/Elixir is needed to run either command. You can copy just
`dist/pocket-live` to another compatible machine and use it in both terminals.

## Inspect and change the running application

```elixir
iex> System.pid()
# This is the PID printed by `serve`, not the console client's PID.

iex> Live.Counter.value()
iex> Live.Counter.add(1000)
iex> :sys.get_state(Live.Counter)
iex> Supervisor.which_children(Live.Supervisor)
iex> Process.info(Process.whereis(Live.Counter), [:memory, :message_queue_len])

# Stop just the worker: its supervisor will start a fresh one.
iex> Process.exit(Process.whereis(Live.Counter), :kill)
iex> Live.Counter.value()
```

Ctrl-D detaches. Reattach to see the same running app. Exceptions at the prompt
do not stop the application. `System.halt()` **would** stop the actual service,
so do not use it to disconnect.

## Diagnostics and shutdown

```sh
./dist/pocket-live --status
./dist/pocket-live --observe
./dist/pocket-live --stop
```

`--status` returns JSON. `--observe` returns a process snapshot ranked by memory,
with reductions and mailbox sizes. `--stop` runs application shutdown callbacks
and removes the private socket directory.

To select a second instance:

```sh
POCKET_CONSOLE_DIR="$HOME/.pocket-live-second" ./dist/pocket-live serve
./dist/pocket-live --console "$HOME/.pocket-live-second"
./dist/pocket-live --stop "$HOME/.pocket-live-second"
```

The socket directory must be new and have a trusted parent. After a hard kill,
Pocket deliberately refuses to overwrite a stale directory; confirm the old
process is gone before removing it.

This is a local administrative console, not a security sandbox. It permits
arbitrary code execution as your OS user. The current transport is line-oriented,
without tab completion, job control, or forwarding of the service's global logs.
