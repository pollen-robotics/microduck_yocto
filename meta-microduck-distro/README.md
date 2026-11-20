# meta-microduck-distro

The `microduck` distro (`conf/distro/microduck.conf`): oe-core's defaults
plus the robot's policy (systemd, NetworkManager, the default distro features a
headless robot opts out of, the services it does not run). No poky.

Depends on: openembedded-core.

Part of https://github.com/pollen-robotics/microduck_yocto, built with
`kas/microduck.yml`; see the repository's README.md and AGENTS.md.

Licensed under Apache-2.0, like the rest of the repository (`LICENSE`).
