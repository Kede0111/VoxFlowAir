# Security Policy

## Supported versions

Security fixes go into the latest release.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private reporting instead: on the repository page,
open **Security › Report a vulnerability**. Include the VoxFlowAir and macOS versions, what an attacker
could do, and steps to reproduce.

Areas where a vulnerability matters most:

- the **VoxFlowAir Micro driver** (`Driver/`), which macOS loads into `coreaudiod`;
- the **local control** channel (`~/Library/Application Support/VoxFlowAir/control/`), disabled unless the
  `ENABLED` file exists;
- **preset import**, which reads `.voxpreset` files that may come from other people.

You should get an answer within a week. Once a fix is released, the report can be published with
credit to you if you wish.
