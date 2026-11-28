# Clean-host CI uses init dry-run
<!-- adr-header v1 -->
> **Status:** accepted
> **Decision:** `clean-host-install` installs the packed CLI under an empty `HOME` and runs `zenoforge init --yes --dry-run` on Ubuntu and macOS; it does not execute the mutating setup path.
> **Do not:** give the clean-host job write access to repository labels or variables
> **Rejected:** running full init with repository write credentials
> **Terms:** clean-host install, `init --dry-run`, doctor, GitHub Actions

The job checks tarball installation, host preflight and init planning. Full init writes repository labels and variables, so the CI proof uses read-only repository access and leaves those mutations outside the job.

## Consequences
- The check proves package installation and doctor/init planning on both runner platforms.
- Checkout, configuration writes and scheduler installation are not exercised by this job.
