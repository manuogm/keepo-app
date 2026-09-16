# Walkthrough clips

Four silent looping clips, one per step of `ShortcutsWalkthrough.steps`.
**The flow builds and runs with this folder empty** — every clip is optional
and the walkthrough falls back to its written step, which is the durable
half anyway (VoiceOver, Reduce Motion, and the fact that Shortcuts' UI will
move again long before the words stop being true).

## File names — these are the contract

The base name must match `WalkthroughStep.clip` exactly:

| Step | File |
|---|---|
| 1 — Add the shortcut | `walkthrough-1-add-shortcut.mp4` |
| 2 — Open Automation, tap + | `walkthrough-2-new-automation.mp4` |
| 3 — Choose Wallet, pick cards | `walkthrough-3-choose-wallet.mp4` |
| 4 — Run Immediately → Keepo Capture | `walkthrough-4-run-shortcut.mp4` |

## Specs

- **Portrait**, HEVC, **no audio track at all** (not a silent one — muting a
  track still ships its bytes, and an AVPlayer with audio can duck whatever
  the user is listening to).
- **≤10 s each, ≤2 MB each, ≤8 MB total.** They ship in the app binary
  because onboarding has to work offline and on first launch.
- Record on a **real device** — Shortcuts' automation UI does not exist on
  the Simulator.
- Show only the step. No cursor, no preamble, no end card; the clip loops.

## How they are rendered

`WalkthroughClipView` looks each file up by base name and draws nothing
when it is absent, so the walkthrough is complete and correct with this
folder empty — which is how it ships today. It also **declines to play at
all under Reduce Motion**: a looping video is exactly the kind of
unsolicited repeated movement that setting exists for, and the written step
beside it says the same thing.

Drop the files in here and they are picked up — this folder is a folder
reference in `project.yml`, so no target membership to set.
