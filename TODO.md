# TODO

## GitHub repo settings

These are done on GitHub, not in the repo files.

- [ ] **Turn on private vulnerability reporting.** Settings → Code security → Private
      vulnerability reporting → Enable. `SECURITY.md` and the "Report a security vulnerability"
      link in `.github/ISSUE_TEMPLATE/config.yml` don't work until it's on.
- [ ] **Create the `test report` label.** Issues → Labels → New label. The Test report issue
      template applies it, and GitHub doesn't create it by default. (`bug`, used by the Bug
      report template, exists by default; check it hasn't been deleted.)
- [ ] **Create `help wanted` and `good first issue` labels** if they aren't there already.
      GitHub creates both by default in new repos.
- [ ] **Open an issue for each item in the README's "Not yet tested" list**, labelled
      `help wanted` (and `good first issue` where it's a simple check, e.g. trying the steps on
      macOS).
- [ ] **Add a branch ruleset on `main`** that requires the CI checks (`shellcheck` and the
      Ubuntu `tests` job) to pass before merging. Settings → Rules → Rulesets → New branch
      ruleset. Don't require the macOS job while it's allowed to fail.

## CI

- [ ] **Check the first CI run.** It hasn't run yet. Newer ShellCheck on GitHub's runners may
      report checks that local 0.9.0 doesn't, and the issue forms only get validated once pushed.
- [ ] **Check the scripts keep their executable bit** when first committed: `git ls-files -s`
      should show `100755` for `sbx-signing-agent`, `tests/run.sh` and `tests/fake-bin/sbx`.
- [ ] **Pin `actions/checkout` to a full commit SHA** in `.github/workflows/ci.yml` instead of
      `@v4`, with the version in a comment (e.g. `@<sha> # v4.x.y`).
- [ ] **Remove `continue-on-error` from the macOS tests job** once it passes, then update the
      README's platform notes and require the job in the `main` ruleset.

## Readiness checks (before dropping "experimental")

Against real sbx and GitHub. Record OS, `sbx version` and `ssh -V`, then move each confirmed item
from "Not yet tested" to "Checked against real sbx" in the README.

### Must pass

- [x] **End to end:** after `sbx-signing-agent start`, a new sandbox with the kit shows only the
      signing key in `ssh-add -L`, your host identity in
      `git --no-pager config --global --get-regexp '^user\.'`, a good signature in
      `git --no-pager log --show-signature -1`, and "Verified" (with the agent key's fingerprint) on GitHub.
      (v0.54.0: all confirmed, except that `--show-signature` needs an allowed-signers file listing
      the agent key, in the sandbox and on the host.)
- [x] **Terminal independence (P1):** a sandbox started or joined from a terminal whose
      `SSH_AUTH_SOCK` points at the main agent still sees only the signing key. (v0.54.0)
- [x] **Signing only:** in the sandbox, `ssh -T git@github.com` can't log in with the forwarded
      key, and `ssh-keygen -Y sign` with a namespace other than `git` is refused. (v0.54.0: other
      namespaces refused for every built-in agent; `ssh-add -T` gets `agent refused operation`.
      `ssh -T` itself never reaches authentication, because the network policy closes it.)
- [x] **Fails closed:** after `sbx-signing-agent stop`, commits in a running sandbox fail to
      sign, and creating or starting a sandbox with the kit is refused. (v0.54.0: commits fail.
      sbx does **not** refuse to create or start the sandbox; it starts without a working agent.
      The README now says so.)
- [x] **Lifetime:** with `SBX_SIGNING_LIFETIME=2m`, the sandbox shows `The agent has no
      identities` after expiry, and `start` brings the key back without a sandbox restart.
      (v0.54.0)
- [x] **No kit, no agent:** a plain `sbx create claude` sandbox gets no agent while the signing
      agent runs. (v0.54.0, for every built-in agent.)
- [x] **No main-agent keys leak in** at any point. (v0.54.0, with a decoy key in the terminal's
      agent.)
- [ ] `tests/run.sh` passes on a clean machine.

### Should pass

- [x] The kit works with `--clone`, including the HTTPS remote rewrite and a push with the PAT.
      (v0.54.0: the clone inherited the host's `git@github.com:` URL, and with the rewrite the
      push went over HTTPS with the PAT.)
- [ ] In clone mode, a `local` `user.*` or `gpg.*` setting in the host repo doesn't appear in the
      sandbox's clone (check with `git --no-pager config --show-scope --show-origin --get-regexp
      '^(user|gpg|commit|tag)\.'` inside it). If confirmed, add "(clone mode isn't affected)" to
      the README's "If you leave out `--clone`" note.
- [x] `sbx kit add` on an existing sandbox works; record whether files in a sandbox without a
      workspace survive, and update the README either way. (v0.54.0: files survive, but the agent
      isn't connected. The README now says to recreate the sandbox instead.)
- [ ] **Report the `kit add` agent bug** at https://github.com/docker/sbx-releases/issues, and
      recheck on newer sbx. If it's fixed, bring back `kit add` in the README, with its
      permission prompt.
- [x] Restarting the agent process (`stop`, then `start`) while a sandbox runs: record whether
      signing works without restarting the sandbox. (Works on v0.54.0.)
- [x] Claude Code starts in auto mode, not bypass, with the README's settings, in both direct and
      clone mode; `--dangerously-skip-permissions` is blocked. (Confirmed on v0.54.0.)
- [x] Record the default of `sbx settings get kit.allowLocalKits` on a fresh install. (`true`
      on v0.54.0.)
- [ ] With `user.email` unset on the host, sandbox creation is refused.
- [ ] A token with only the README's suggested permissions works for `git push`, `git pull` and
      `gh pr create` in the sandbox; record whether sbx needs anything more.
- [ ] A changed name or email (e.g. the optional "(agent)" suffix) survives a sandbox restart. (Also add this to the
      README's "Not yet tested" list.)

### Nice to have

- [ ] macOS: `tests/run.sh` and the end-to-end check, or state that it's Linux-only.
- [x] A PEM-format key without a `.pub` file, or document it as unsupported. (Unencrypted
      works; encrypted is refused with instructions. Covered by `tests/run.sh`.)
- [x] One agent other than Claude Code. (All built-in agents on v0.54.0.)
