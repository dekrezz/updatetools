# Security Policy

## Supported versions

Security fixes are provided for the latest revision of the `main` branch.
Older revisions are not supported.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities in a public issue, discussion, or
pull request.

Use GitHub's private
[Report a vulnerability](https://github.com/dekrezz/updatetools/security/advisories/new)
form instead. Include:

- the affected commit or version;
- the macOS version and relevant environment details;
- clear reproduction steps;
- the expected and observed behavior;
- the potential impact; and
- a suggested fix, if you have one.

Remove passwords, tokens, personal data, and other secrets from logs before
attaching them.

You should receive an acknowledgement within 72 hours and a status update
within seven days. Please allow time for a fix before publishing details.

## Security-sensitive areas

Reports are especially useful when they involve:

- privilege escalation or sudo credential handling;
- command or shell injection;
- update download integrity and code-signing verification;
- unsafe application replacement or deferred update behavior;
- insecure temporary files, permissions, or cleanup; or
- unintended disclosure of local system information.
