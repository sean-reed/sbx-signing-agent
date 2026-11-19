# Contributing

Contributions are welcome: bug reports, test results, documentation fixes and code. You don't
need to ask before opening an issue or a small pull request. For a larger change, open an issue
first so we can agree on the approach.

**Found a security problem?** Don't open a public issue. Report it privately as described in
[SECURITY.md](SECURITY.md).

## What helps most right now

The most useful contribution is **trying it on a setup the maintainer hasn't**. The README's
[Not yet tested](README.md#testing-status-and-limitations) list says what's unconfirmed, for
example:

- macOS (and WSL2, if `sbx` runs inside it);
- whether `sbx kit add` connects the agent on sbx versions newer than v0.54.0;
- new built-in agents, or new sbx versions, against the checks in the README.

A test report is a real contribution even if you change no code. Use the **Test report** issue
template; it asks for the versions needed to update the README.

## Before you open a pull request

Run both of these from the repo root. CI runs them too.

```bash
tests/run.sh
shellcheck sbx-signing-agent tests/run.sh tests/fake-bin/sbx
```
The tests use a stand-in `sbx`, throwaway keys and their own agents in a temporary folder; they
never touch your SSH agent, `~/.ssh` or sbx settings. They need OpenSSH 8.4 or later and git 2.32 or later.

If you change the startup command in `kits/sbx-signing-agent/spec.yaml`, CI also checks it with
`shellcheck -s sh`.

## Rules for changes

These aren't obvious from the code, but they're why the project exists:

- **Fail closed.** The script must never fall back to the caller's `SSH_AUTH_SOCK`, load the key
  into any agent but its own, or kill an agent it didn't start. If something is unexpected, stop
  with an error.
- **Bash 3.2.** The script must keep working with macOS's bash 3.2, so no `mapfile`,
  `readarray`, associative arrays or `${var,,}`. The guard at the top of the script must stay
  POSIX `sh`.
- **Tests for behaviour.** New or changed behaviour needs a test in `tests/run.sh`. Tests run
  against `tests/fake-bin/sbx`, never a real `sbx`, and must not touch the user's agent or files.
- **The kit stays narrow.** Don't widen what the kit grants (for example `unrestricted: true`, or
  `sign` namespaces other than `git`) without discussing it in an issue first.
- **README style.** After each command that changes the user's system, say in bold what it
  changes ("**Changes sbx settings.**") and how to undo it. Commands that only read or print
  need no label. Say plainly what has and hasn't been tested, and with which versions.
- **ShellCheck clean.** If a warning is a false positive, disable it on that line with a comment
  explaining why.

## Licence

This project is licensed under [Apache-2.0](LICENSE). By submitting a contribution, you agree it's
licensed under the same terms, as section 5 of the licence describes. There's no CLA to sign.

## What to expect

This is a small project with one maintainer, so reviews are best effort. Expect a first reply
within about a week. If a pull request goes quiet, a polite ping is welcome.
