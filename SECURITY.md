# Security

Nook handles people's email, so security reports get priority.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub: go to the repository's **Security** tab
and choose **Report a vulnerability**. Only the maintainers can see the report.

Useful details: what an attacker can do, the steps to reproduce (in `--demo` mode if possible), and the Nook
version and macOS version. We aim to acknowledge reports within a few days and will credit you in the fix
unless you'd rather stay anonymous.

## Scope

Especially interesting:

- Reading or leaking mail, tokens or the database key from outside Nook
- Remote content or scripts loading from a rendered email despite blocking
- Anything that sends, deletes or changes mail without the user doing it, including through `nook://` links
  or the MCP server
- Header or content injection into outgoing mail

Out of scope: attacks that need malicious software already running as the same macOS user. See
"What encryption does and doesn't protect against" in the README.
