## Description

<!-- Provide a concise description of the changes made and the motivation behind them. -->

---

## Licensing & Provenance Checklist

Please confirm that your changes strictly adhere to Tinux licensing standards:

- [ ] **No GPL / Third-Party Contamination:** This pull request contains NO source code, comments, or adaptations from the Linux kernel, GNU tools, BusyBox, or any GPL-licensed project. All code is written from scratch in Zig.
- [ ] **No Compiled Binary Blobs:** No binary artifacts (`.elf`, `.bin`, `.so`, `.o`, `.cpio`, `.tar`, `.exe`) are committed or tracked in git.
- [ ] **Signed-off-by (DCO):** All commits include a Developer Certificate of Origin sign-off (`git commit -s`).
- [ ] **Dual Licensing:** I agree that this contribution is submitted under the project's dual license (**MIT OR Apache-2.0**).

---

## Quality & Verification Checklist

- [ ] `python scripts/check_license_guardrails.py` passed with 0 violations.
- [ ] `bash scripts/check_specs.sh` passed with all specifications READY.
- [ ] `zig build` passed with zero errors and zero warnings.
- [ ] Relevant QEMU tests (`scripts/verify_qemu.sh <TASK>`) passed with exit code 0.
- [ ] All code and documentation conforms strictly to 7-bit ASCII (`ord <= 127`).
