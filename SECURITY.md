# Security policy

Castellan is a tool that hardens other machines, so its own integrity matters.
This document explains which versions receive fixes and how to report a problem
responsibly.

## Supported versions

Fixes are published for the latest released version. The 1.x line is the
maintained series; earlier pre-release 0.x versions no longer receive fixes.

| Version | Supported |
|---------|-----------|
| 1.x | yes |
| < 1.0 | no |

If you installed via apt, `sudo apt update && sudo apt upgrade` keeps you on a
supported version.

## Reporting a vulnerability

Please do not open a public issue for a security problem. Report it privately,
either way:

- Preferred: open a private advisory through GitHub Security Advisories at
  https://github.com/SIIR3X/castellan/security/advisories/new
- Or email Lucas Fagioli at lucas.fagioli576@gmail.com with the subject line
  "castellan security".

Include enough to reproduce: the Castellan version, the control machine and target
OS, the configuration or command used (with secrets removed), and the impact you
observed.

What to expect:

- Acknowledgement within 5 business days.
- An assessment and, if confirmed, a fix plan with a target timeframe.
- Credit in the changelog and the advisory, unless you ask to stay anonymous.
- Coordinated disclosure: please give a reasonable window for a fix before any
  public write-up.

## Scope

In scope, problems in Castellan itself, for example:

- A defect that breaks the anti-lockout guarantees (cutting access before the new
  access is verified, reloading sshd mid-run, an unusable rollback).
- A hardening role that weakens a setting it claims to harden, or leaves a host
  less secure than before.
- Any handling that writes, logs or leaks a secret (initial password, sudo
  password, private key) contrary to the rules in docs/config.md.
- Injection or privilege issues in the wrapper, the inventory script or the
  packaging.

Out of scope:

- Vulnerabilities in the target operating system, Ansible, or third-party packages
  that Castellan only configures. Report those upstream.
- A host left exposed because a role was disabled, a profile was too low, or an
  optional measure was not enabled. Castellan reduces the attack surface; it does
  not promise absolute security (see docs/security-measures.md).

## Good practice when running Castellan

- Keep an out-of-band console (provider KVM or rescue mode) available during the
  first apply, and take a snapshot if your host allows it.
- Always run `castellan audit` before `apply`, and review the diff.
- Keep your admin private key passphrase-protected and loaded only in your
  ssh-agent; Castellan never reads it.
