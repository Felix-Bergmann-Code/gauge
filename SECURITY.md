# Security Policy

## Reporting a vulnerability

Please **don't** open a public issue. Report it privately through GitHub instead:
**[Security → Report a vulnerability](https://github.com/Felix-Bergmann-Code/gauge/security/advisories/new)**.

You'll get a reply as soon as possible. Once a fix ships, you'll be credited unless you'd rather not be.

## What Gauge touches

Gauge is read-only. It reads system counters (Mach host statistics, IOKit, the SMC, `sysctl`) and runs `/bin/ps` while a CPU or Memory popover is open. It needs no special permissions, makes no network requests and writes nothing except its own preferences.
