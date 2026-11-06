# Building on HF Jobs — what an agent needs to know

`scripts/build-hfjob.sh` is the build host. `README.md` explains the mechanism;
this is what goes wrong.

## The job status lied for a week, and now it does not

Every build from 2026-09-10 to 2026-09-18 reported terminal stage `ERROR`, exit 1,
after every task succeeded. The cause was found by bisection with `cpu-basic`
probes in the real image and fixed in `build-hfjob.sh`: the job ran under
`bash -lc`, a **login** shell sources `~/.bash_logout` on `exit`, the kas image's
stock Debian one runs `clear_console -q` when `SHLVL=1` (which gosu guarantees),
there is no tty so it fails, and `set -eu` promoted that to the shell's exit
status. `bash -c` is the whole fix; `kas` resolves on the image's default PATH.

Local reproductions all passed because the laptop had `SHLVL=4`, so its own
`.bash_logout` guard never fires. When a container-only failure will not
reproduce locally, probe the container: a `cpu-basic` job costs cents and takes
a minute.

`scripts/wait-hfjob.sh` still judges on the log rather than the stage. That was a
workaround for this; it is kept because it is also the more robust rule.

`hf jobs logs` frequently returns **nothing** for an in-progress job. It works
once the job is terminal. Do not read an empty log as "no output yet — fine".

`hf jobs inspect --json` returns a **single-element array**. `jq '.status.stage'`
gives empty; use `(.[0]? // .) | .status.stage`.

## The input sync left a deleted file behind, and it killed the parse

**Fixed 2026-10-05: `build-hfjob.sh` now copies `kas/` and `meta-microduck/`
into a fresh temp directory, so every job syncs into a folder of its own.** The
history below is why.

`hf jobs -v ./meta-microduck:/src/meta-microduck` syncs into a **stable**
bucket prefix (`jobs-artifacts/meta-microduck-<hash>`). The hash is
`sha256(hostname:absolute path)[:8]`, and the sync runs with `delete=False`:
read in huggingface_hub's `_jobs_api.py` (`_derive_job_volume_name`) and
`hf_api.py` (`sync_job_volume`). So a file removed from the repo stays in the
prefix, and every job mounts it.

It broke builds twice:
- **2026-09-21:** renaming a file locally uploaded the new name and left the old
  one in the bucket, so both were mounted.
- **2026-10-05:** on GitHub the checkout path is the same for every run, so all
  branches shared one prefix. A main-based branch's run built the
  `microduck-daemon_0.15.0.bb` a `beta-board` run had uploaded, with main's
  crate list, and failed in `do_compile`.

A stale `.bbappend` fails the **entire parse** (`ERROR: No recipes in default
available for: .../u-boot-rockchip_%.bbappend`). A stale `.bb` is not benign
either: bitbake takes the highest `PV`, which is how the October run built a
recipe that didn't belong to its branch.

To see what a job actually mounted:

    hf jobs inspect <ns>/<id> --json | jq -r '(.[0]? // .) | .volumes[]'

## Verify the artifact before flashing, not after

A build can succeed and produce the wrong thing, and a download can be
incomplete while looking like a file. Three checks, all cheap:

1. **The local file is complete.** `curl -o` writes in place, so a `dd` of a
   file still downloading produces a *torso*: the new GPT and the early
   partitions are complete, everything past the download's frontier is whatever
   the card held before. Such a card **boots** — `rootfs_a` ends at 2.2 GB — and
   then fails somewhere later in the layout in a way that looks like a build
   bug. It happened with the data partition at 4.4 GB: `blkid` found no
   filesystem because the bytes had not arrived. Compare the size to the
   bucket's `content-length`, or the sha256 to the one reported, before the dd.
   Guard the command: `[ "$(stat -c%s f.wic)" = <expected> ] && sudo dd ...`.
2. The `.wic` filename says which image: `microduck-image-dev-...` vs
   `microduck-image-...`. Prod has no password-less root. This was missed once
   and cost a flash of a card nobody could log into.
3. GPT partition names, with a 17 KB range request rather than a 12 GB download:

       curl -sfL -r 0-17407 -H "Authorization: Bearer $T" "$B/<image>.wic" \
         | tr -d '\0' | grep -oE "[a-z_]{4,10}" | sort -u

   Expect `boot boot_b data rootfs_a rootfs_b uboot uboot_env`. `boot` present
   is the one that matters — see `rauc.md`.

The bundle's real name is in the log (`grep -oE 'microduck-bundle-...-[0-9]+\.raucb'`);
fetching the unversioned symlink name 404s.

## The cache

`/cache/downloads` and `/cache/sstate` are content-addressed, so concurrent
writers are safe; only *interrupted* writes corrupt. `save()` publishes each file
via `cp` to `.part` then `mv`, so a reader sees absent-or-complete, never partial.

A wks-only change rebuilds almost nothing (7083 of 7568 tasks from sstate). A
kernel fragment or a new layer is a cold-ish build, 50–80 min.

## Secrets

The only two things that travel to the job as secrets are the SSH deploy key
(`HFJOB_SSH_KEY`, base64) and the RAUC signing key (automatic, bundle targets
only). Both via `-s`. Nothing else may be baked in — a credential in an image
cannot be rotated without reflashing every robot.

## Running it from an agent

`build-hfjob.sh`, `sh`, `bash`, `timeout`, `hf` and sourcing `kas/*.env` are all
blocked by the local shell allowlist, and the block is **not deterministic** —
the same invocation has passed once and been refused the next time. Hand the
command to the human rather than retrying:

    KAS_BUILD_DIR=<build dir> HFJOB_TARGET=microduck-bundle scripts/build-hfjob.sh

`KAS_BUILD_DIR` is what `kas/local.env` sets (the signing keys live under it);
passing it inline avoids sourcing.
