# Security Policy

## Supported Versions

Tinux is actively developed. Critical security fixes are applied to the latest `main` branch.

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |

## Reporting a Vulnerability

We take the security and integrity of Tinux seriously. Because Tinux is an operating system kernel running in Ring 0 with hardware-level privileges, memory safety, privilege separation, and isolation vulnerabilities require careful handling.

If you discover a security vulnerability or privilege escalation flaw in Tinux:

1. **Do NOT report security vulnerabilities via public GitHub issues, discussions, or pull requests.**
2. Use **GitHub Private Vulnerability Reporting**:
   - Navigate to the [Tinux Security Advisories](https://github.com/tahigash/tinux/security/advisories/new) page.
   - Click **Report a vulnerability** to submit an advisory privately.
3. Include detailed information to help us reproduce and resolve the issue:
   - A description of the vulnerability and affected kernel subsystem.
   - Step-by-step reproduction instructions or a minimal test binary/script.
   - Any proposed fix or mitigation, if available.

### Disclosure Process

- We will acknowledge receipt of your vulnerability report within 48 hours.
- We will coordinate a fix and publish a patched version along with a security advisory acknowledging your contribution.
