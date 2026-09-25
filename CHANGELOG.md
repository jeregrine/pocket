# Changelog

## 0.1.0-alpha.1

Initial experimental release.

- Build a Mix project into one native executable with `mix pocket.build`.
- Support module and MFA entry points, with CLI arguments passed first.
- Verify a pinned AOT toolchain before execution and record it in `pocket.lock`.
- Compile in an isolated production build directory.
- Package the runtime application closure without Mix, Hex, or the Pocket builder.
- Support Unicode arguments, stdin pipes, exit codes, and bounded OTP shutdown.
- Emit a JSON build inventory alongside the executable.

This release uses an experimental upstream runtime. Native dependency packaging,
cross-compilation, custom releases, umbrella projects, and `runtime.exs` are not
supported. See the README for platform and security limitations.
