# <img src="MacApp/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="40" alt="VisionDrop icon" align="top" /> VisionDrop

Drag-and-drop file transfer between a Mac and Apple Vision Pro over the USB-C
Developer Strap — at **18.5 Gbps sustained** (2.3 GB/s, writing to disk). A
25 GB file lands in about 10 seconds.

Drop files on the Mac app and they appear in Files → On My Vision Pro →
VisionDrop. Pick files on the headset and they land in the Mac's ~/Downloads.
Live progress, speed, and ETA on both ends; a USB/WiFi badge that tells you
which path you're actually on; cancel buttons; and a persisted, clearable
transfer history.

No network configuration required — plug in the strap and drop. No WiFi
toggling, no DHCP, no static IPs, no bridge setup.

## Measured (Gen 2 Developer Strap, M-series Mac)

| Path | Speed |
|---|---|
| iperf3 (memory to memory, no disk) | ~19 Gbps |
| Files app / Safari download | ~5 Gbps |
| a-shell `curl` (5 GiB, cache-friendly) | 13.8 Gbps |
| **VisionDrop (25 GB sustained, to disk)** | **18.5 Gbps** |

## Why this is effectively the maximum

18.5 Gbps is ~97% of what iperf3 achieves on the same cable *without touching
a disk*. Going faster would mean moving bits faster than the link carries
them. There is no serial stage left in the pipeline: four parallel raw-socket
streams read the file, cross the wire, and write to the Vision Pro's storage
**concurrently** — and the writes bypass the page cache (`F_NOCACHE`), so they
stream at the SSD's native sustained rate instead of sprinting into RAM and
stalling on writeback. The residual ~3% is TCP/IP and syscall overhead.

## Why not SMB, SFTP, or AirDrop?

- **Speed.** Apple's SMB client and SFTP apps single-stream through
  general-purpose protocol stacks (plus encryption, for SFTP) and top out at a
  fraction of the link; AirDrop peaks around 1–2 Gbps. VisionDrop's wire
  format is a length-prefixed header plus raw payload bytes over kernel
  sockets — the same hot path `curl` uses, times four, with the receive side
  double-buffered.
- **The wrong-lane trap.** The Developer Strap exposes *two* network
  interfaces: the fast USB4 NIC and a slow (~35 Mbps) USB-CDC config lane —
  and both answer connections in under a millisecond. Anything that picks a
  path by address, name, or latency (SMB via Bonjour, manual IPs, mDNS) can
  silently land on the slow lane or WiFi. VisionDrop races a 16 MiB data
  blast down every candidate path and lets measured **bandwidth** pick the
  winner, every transfer.
- **Resilience.** Link-local IPv6 means the fast lane works even when DHCP
  doesn't (hotels, bridges, captive networks). Discovery self-heals after
  reboots and address changes, and a transfer that starts while the fast NIC
  is waking re-races automatically.

## Requirements

- Apple Vision Pro with a **Developer Strap** (Gen 2 for USB4 speeds; the
  original strap is USB 2 and will be ~30× slower)
- Mac with a USB4 / Thunderbolt port, macOS 14+
- For the headset app: either **SideStore** (no Xcode needed) or Xcode with
  the visionOS platform

## Install

**Mac:** download the notarized app from Releases (or build from source).

**Vision Pro** — two options:

*SideStore (no Xcode):* install SideStore on the headset with
[iloader (visionOS release)](https://github.com/rebelancap/iloader/releases#release-visionos),
which sideloads it wirelessly, then install `VisionDropReceiver.ipa` from
this repo's Releases through SideStore.

*Xcode:* build `VisionDropReceiver` from source with your own Apple
Developer team:

```sh
brew install xcodegen
xcodegen generate
# set your DEVELOPMENT_TEAM in project.yml, then either open the project in
# Xcode and Run on your Vision Pro, or:
xcodebuild -project VisionDrop.xcodeproj -scheme VisionDropReceiver \
  -destination 'generic/platform=visionOS' -allowProvisioningUpdates build
scripts/install-receiver.sh   # auto-detects your paired Vision Pro
```

First launch on each side triggers a Local Network permission prompt — allow
it (transfers are blocked without it, and macOS is not always graceful about
re-asking; if transfers inexplicably fail with connection errors, check
System Settings → Privacy & Security → Local Network).

## How it works

- **Wire protocol** (`Shared/WireProtocol.swift`): each TCP connection carries
  one stream of one transfer — 6-byte magic, length-prefixed JSON header
  (transfer id, name, size, offset, length, stream index/count), then raw
  payload. The receiver preallocates the file sparsely, writes each stream at
  its offset with direct I/O, finalizes, then acks.
- **Discovery**: each side advertises `_visiondrop._tcp` via Bonjour with its
  IPv4, routable IPv6, and link-local IPv6 addresses in the TXT record, plus
  the raw data port.
- **Path selection** (`Shared/SenderModel.swift`): raw-socket handshake race
  across every advertised address (link-locals probed sequentially per address
  across scope interfaces — concurrent same-address scoped connects poison
  each other), then a 16 MiB bandwidth blast down all survivors; first pong
  wins. Winners under 400 Mbps trigger one delayed re-race.
- **Data plane** (`Shared/BSDSocket.swift`, `Shared/ReceiverModel.swift`):
  everything is kernel sockets. Network.framework is used *only* for Bonjour —
  its path evaluation refuses bridge interfaces in app contexts and its
  receive path tops out around 5 Gbps. Sender streams are blocking
  `pread`→`write` loops; receiver streams are double-buffered
  (network-read thread + `F_NOCACHE` `pwrite` thread per stream).
- Stream count is tunable live: `defaults write com.rebelancap.visiondrop
  VDStreams -int N` (default 4).

## Development

`scripts/loopback-test.sh` compiles the production sender and receiver into a
CLI harness and runs real transfers over loopback (byte-for-byte verification,
collision-safe naming, temp-file cleanup, blast path). The `.xcodeproj` is
generated — edit `project.yml`, not the project. `server.js` is a standalone
high-throughput HTTP file server kept around as a fallback for devices without
the app (a-shell `curl` reaches ~13.8 Gbps against it).

## Roadmap

- Resume partial transfers; per-stream retry
- Optional integrity check (xxHash) after landing
- Optional "USB only" mode

## License

MIT
