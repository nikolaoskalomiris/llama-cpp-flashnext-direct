# AI Director Direct build contract

This directory is the narrow AI Director build/provenance layer for this Direct fork. It intentionally coexists with the upstream-style llama.cpp presets and workflows instead of replacing them.

## Two CUDA version identities

The reference **build toolchain** is CUDA Toolkit 13.3 with `nvcc` V13.3.73. The installed AI Director product uses the separate shared-runtime identity `CUDA13.3.1-Dual-Shared-v2`. The compiler build number and the product runtime-stack identity describe different things. These scripts do not bundle, install, update, or replace the AI Director shared CUDA runtime.

## Artifact identity

`direct-build-contract-v1.json` contains the pinned Windows x64 reference toolchain, configure policy, CUDA architecture policy, and the 17-file shipping allowlist.

The accepted AI Director 0.3.22 hashes in the contract are **historical authority references**. A source build is not promoted to those official identities merely because it uses the same compiler versions or because some hashes happen to match. The normal release acceptance process is required before any source-built bytes can replace an accepted runtime artifact.

A build using every reference tool hash is labeled `AI_DIRECTOR_DIRECT_REFERENCE_TOOLCHAIN_BUILD_NOT_OFFICIAL_ACCEPTED`. A build made with an explicitly allowed toolchain mismatch is labeled `AI_DIRECTOR_DIRECT_LOCAL_CUSTOM_UNATTESTED`.

## Reference build

Requirements on Windows x64:

- Visual Studio 2022 Build Tools with MSVC 14.44.35207, including the bound `cl.exe`, `link.exe`, and `lib.exe`;
- Windows SDK 10.0.26100.0;
- CMake 3.31.6-msvc6 and Ninja 1.12.1 from the bound Visual Studio installation;
- CUDA Toolkit 13.3 with `nvcc` V13.3.73;
- no `CL`, `_CL_`, `NVCC_PREPEND_FLAGS`, or `NVCC_APPEND_FLAGS` injection;
- no discoverable `ccache.exe` (the configure option remains `GGML_CCACHE=ON`, but the proven reference environment had no ccache executable);
- a clean Git worktree whose code is still based on the contract's source baseline.

From the repository root:

```powershell
.\aidirector\build-windows-cuda13.ps1
```

The script verifies the bound tool hashes, initializes `vcvars64.bat -vcvars_ver=14.44`, verifies that `cl.exe`, `link.exe`, `lib.exe`, `rc.exe`, and `mt.exe` resolve to the bound paths, and fails if `ccache.exe` is discoverable. It requires fresh non-existing build/output roots outside the checkout, configures a single-config Ninja Release build, keeps `CMAKE_CUDA_ARCHITECTURES` unset, disables both UI provisioning paths, copies only the 17 allowlisted shipping files, and writes `direct-build-provenance.json` next to the shipping directory.

If a maintainer intentionally wants a non-reference toolchain, `-AllowCustomToolchain` permits hash mismatches but forces the custom/unattested identity class. It does not authorize release promotion.

## Independent shipping-set verification

```powershell
python .\aidirector\verify-direct-shipping-set.py `
  --shipping-dir <path-to-shipping-directory> `
  --report <path-to-verification-report.json>
```

By default this verifies the exact 17 filenames and records each SHA-256 against the accepted historical reference. It does **not** require accepted hashes, because ordinary source builds have their own identities. `--require-accepted-hashes` exists only for explicit historical-byte audits.

For a static contract check with no build:

```powershell
python .\aidirector\verify-direct-shipping-set.py --contract-only --repo-root .
```

## Network and UI policy

The reference configure sets `FETCHCONTENT_FULLY_DISCONNECTED=ON`, `LLAMA_BUILD_UI=OFF`, and `LLAMA_USE_PREBUILT_UI=OFF`. No dependency download is part of this recipe. This is a build-policy statement, not a claim that the operating system has been placed in a network sandbox.

## CI boundary

`.github/workflows/aidirector-direct-contract.yml` performs static contract validation on every push and pull request, so later source changes cannot silently drift outside the pinned baseline contract. The actual reference CUDA build is manual and targets a specifically labeled self-hosted Windows x64 runner that must already contain the exact bound toolchain. This avoids silently treating the repository's generic Windows CUDA workflow or a changing GitHub-hosted image as equivalent to the AI Director reference toolchain.
