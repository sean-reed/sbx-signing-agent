## What this changes and why

<!-- Link the issue if there is one, e.g. "Fixes #12". -->

## How it was tested

<!-- Which tests you ran, and on what: OS, `sbx version`, `ssh -V`. Say if you tried it with real sbx. -->

## Checklist

- [ ] `tests/run.sh` passes
- [ ] `shellcheck sbx-signing-agent tests/run.sh tests/fake-bin/sbx` is clean
- [ ] New or changed behaviour has a test
- [ ] Still works with bash 3.2 (no `mapfile`, associative arrays or `${var,,}`)
- [ ] Doesn't weaken fail-closed behaviour or widen what the kit grants
- [ ] README updated if behaviour, commands or testing status changed

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the reasons behind these.
