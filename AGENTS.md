# AGENTS.md

Project overview is available at `README.md`.

This project is security-focused, and aims to be clean and elegant.

## General guidelines

Some guidelines are:

- Make changes carefully with security hardening in mind.
- Keep things auditable and readable.
- Do not add unnecessary features or useless/redundant code.
- Do not add dependencies outside of the built-in macOS CLI tools.

In general, follow zero trust principles as much as possible.

## New sandbox exceptions

Pay attention when adding new build sandbox (Seatbelt profiles) exceptions.
Generally, the added exceptions must be required for a valid reason,
strictly scoped to a stage, and the exceptions must be the minimal set
that has to be allowed (no broad permissions) for the new feature to
work. You may do ablations if guessing and researching are not enough.

The same holds for app sandbox entitlements, though it is not likely they
need to change unless explicit confirmation from the user.

## Target system

The target system is modern macOS running on Apple Silicon (arm64)
hardware. No older systems or architectures have to be considered. In fact,
do not keep compatibility paths for such systems as they can bloat code or
add unneeded attack surface.

This extends to all the tools used by the project, which happen to be
all sourced from macOS.

## Workflow

When making contributions on behalf of the user, be clear and informative
about the changes that were made and the reasoning behind them.
