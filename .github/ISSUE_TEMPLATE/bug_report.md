---
name: Bug report
about: Something is wrong with the emulator
title: ""
labels: bug
assignees: ""
---

**What were you running?**

- Frontend (browser / Roblox Studio / headless) and the exact command
- Game, BIOS, and checkpoint involved (filenames only, don't attach the files)
- Flags such as `cpi`, `--seconds`, `--bios-probe-seconds`

**What did you expect, and what actually happened?**

**If the headless boot check printed FAIL, paste the EVIDENCE and BLOCKER lines.**

`cdActivity`, GPU frame flips, PC advancement, pad setup, and input acceptance each have their own EVIDENCE line, and the BLOCKER line names the first failure. A FAIL is often just a too-short window. Include the verdict from a longer run (`--seconds 20`) if you tried one.

**Environment:** OS, Lune/Rojo versions, Studio build (if Roblox frontend)

- [ ] I'm not including copyrighted BIOS, disc, or checkpoint data (gitignored for a reason)