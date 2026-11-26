# Asset Policy (Rule #1)

**Nothing from any proprietary title is ever stored in this repository.**
Everything is loaded or translated at runtime on the user's machine from files the user supplies outside the repository tree.

## Prohibited
In any form (files, string literals, fixtures, snapshots, docs):
- Game assets: models, textures, shaders, audio, video, text, `.rpf` / `.ttpf` archives.
- Title executables or DLLs, data sections, tables, resources, or code beyond small interoperability signatures.
- Derived artifacts: converted assets, decompiled code, shader dumps, extracted tables, or screenshots.

## Allowed
- Vasperty engine source code (`src/`) that understands console formats and APIs.
- Small interoperability constants (magic numbers, enum values, GUIDs).
- Synthetic test data generated at runtime by our own test suite (`src/tests/`).

## The One Exception
`src/formats/bcpack-tables.bin` (~78 KiB): constant rANS probability models and dictionaries required to decode BCPack streams. Explicitly allowlisted in `build.ps1` (`Run-Policy`) and `.gitignore`.

## Enforcement
1. `.gitignore` blocks all proprietary archives, binaries, and derived outputs.
2. `.\build.ps1 policy` audits every tracked and untracked non-ignored file in the repository, enforcing extension allowlists and a 512 KiB size cap.
3. At runtime, `vasperty_core.ensure_outside_repo` refuses any cache/data/game path that lands inside the Vasperty source tree (detected via `build.ps1`).
