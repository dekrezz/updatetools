# Contributing to updatetools

Contributions from everyone are welcome. You can fork the repository and open
a pull request without requesting permission.

## Before you start

- For a bug or feature, check existing issues and pull requests first.
- Keep each pull request focused on one change.
- Report security vulnerabilities privately according to
  [SECURITY.md](SECURITY.md), not in a public issue or pull request.

## Development

1. Fork the repository and create a branch from `main`.
2. Make the smallest complete change that solves the problem.
3. Keep the script compatible with the system Bash 3.2 shipped with macOS.
4. Use English for code, identifiers, comments, commit messages, and
   documentation.
5. Run the checks:

   ```bash
   bash -n updatetools
   bash tests/test_manual_apps.sh
   bash tests/test_broken_installs.sh
   ```

6. Open a pull request with a clear description of the problem, the solution,
   and how you verified it.

If a change affects user-visible behavior, update `README.md` in the same pull
request.

## Pull request checklist

- The change is focused and does not include unrelated formatting.
- Existing behavior remains compatible unless the pull request explains an
  intentional breaking change.
- Tests cover new behavior where practical.
- No passwords, tokens, personal data, generated logs, or local machine paths
  are committed.

## Contribution license

By intentionally submitting a contribution for inclusion in updatetools, you
agree to license that contribution under the
[Apache License, Version 2.0](LICENSE).

You retain copyright in your contribution and represent that you have the
legal right to submit and license it. If your employer or another party owns
the work, obtain their permission before submitting it.
