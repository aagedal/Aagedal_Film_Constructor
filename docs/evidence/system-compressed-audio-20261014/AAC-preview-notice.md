# Visible AAC preview qualification — 2026-10-14

The system backend preserves AAC playback so ordinary camera and phone media
remain useful in the timeline. It now marks its playback status:

> AAC source-edge audio is approximate. Normalize to PCM or ALAC for faithful trims.

The notice comes from the selected source track's actual format descriptions,
not its file extension or imported metadata. AAC-LC, HE, HE-v2, LD, ELD,
ELD-SBR, ELD-v2 and spatial AAC format identifiers trigger the notice. This is
conservative labeling, not a qualification of those profiles. No edge distance
is advertised as safe: the retained inset evidence disproves a one-access-unit
margin, and passing generated interior cuts do not establish a universal margin.

The controller retains its representation/transport status and appends the
backend notice after successful seeks and play. Repeated transport actions do
not accumulate copies. Rebuilding to a backend without a notice clears it.
Errors continue to show the actual failure. Import, rendered export, MP3 refusal
and cross-rate audio refusal keep their existing behavior.

The production decoded-mix proof checks that every admitted generated AAC case
has the approximation/normalization notice, and PCM/ALAC cases have no notice.
Results now retain the notice per decoded case. Existing amplitude and sample
extent bounds remain unchanged; edge diagnostic runs still fail on the known
AAC differences. This adds visible qualification, not source-edge parity.

Verification commands:

```sh
bash scripts/sequence-monitor-smoke.sh
python3 -m unittest discover -s scripts -p test_system_audio_mix_proof.py
python3 scripts/system-audio-mix-proof.py /opt/homebrew/bin/ffmpeg \
  /private/tmp/new-aac-notice-proof --include-aac \
  --include-lossless-and-mp3 --include-packet-cuts --include-resampling \
  --expect-resampling-rejection --expect-mp3-rejection
```

`after-aac-notice-combined-results.json` passes 184/184 cases, including
32 admitted AAC interior/packet mixes with the visible qualification notice.
`after-aac-notice-edges-results.json` retains 196 cases: 171 pass and the same
25 AAC edge/inset cases fail the original strict bounds. Every admitted AAC
case has the notice; PCM/ALAC do not. The edge runner deliberately exits nonzero.
Reproduce that diagnostic with `--include-aac --include-lossless-and-mp3
--include-edge-cuts --include-packet-cuts --expect-mp3-rejection`.

The controller lifecycle smoke passes notice publication after seek, persistence
without duplication after play, and clearing after backend replacement. The
three matrix integrity tests pass. Full logs and media are in
`/private/tmp/afc-aac-notice-host-20261014` and
`/private/tmp/afc-aac-notice-edges-host-20261014`. The restricted reader failed
with AVFoundation -11800/-1; host media services were required as before.
