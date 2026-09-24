# Vendored: mediaremote-adapter

Source: https://github.com/ungive/mediaremote-adapter
Commit: 73f14ab1568371e6e3c44063f21c34c5e2712c4d
License: BSD 3-Clause, see `LICENSE` here and `THIRD_PARTY_NOTICES.md`.

Copied unmodified, without its editor settings and helper scripts.
`Scripts/build-adapter.sh` builds `MediaRemoteAdapter.framework` from these
sources, in place of the project's CMake build, which Capacity Notch does not
use; the sources and flags are the ones its `CMakeLists.txt` names, for arm64.

Why it is here: ADR 0004 and ticket 17. It runs as `/usr/bin/perl
mediaremote-adapter.pl MediaRemoteAdapter.framework stream`, because the
private MediaRemote framework answers an Apple platform binary and not an
ordinary process.
