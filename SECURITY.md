# Security

The SDK contains no privileged NUKE or LinkMe credentials. Applications must
exchange their authenticated user session for a short-lived, replay-scoped
capability; access control remains enforced by the ingestion service.

Please do not report suspected vulnerabilities in a public issue. Use the
repository's **Security → Report a vulnerability** flow so maintainers can
investigate privately.
