# Security Policy

## Reporting a Vulnerability

Please use GitHub Private Vulnerability Reporting for this repository.

If private reporting is not available, open a minimal public issue asking for a private contact path and do not include exploit details.

## What to Include

- affected commit, branch, or release
- device and iOS version
- OpenCode version, if relevant
- clear reproduction steps
- impact and expected severity
- proof of concept or logs with secrets removed

## Please Do Not Post Publicly

- passwords or deep links that include credentials
- local IP addresses or private hostnames unless necessary
- screenshots that expose private data
- signing material or other secrets

## Scope

Relevant reports include issues around:

- local-network discovery and connection flows
- deep links and QR setup
- credential handling and storage
- session or workspace data leakage
- code execution, auth bypass, or privilege escalation

Security fixes are made against the latest code on `main`.
