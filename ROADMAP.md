# Roadmap

- Adopt `UnattendedInstallConfig` (replaces the legacy `machine.install` form kept in
  `talos/all/01-install-disk.yaml` during the topf migration for a clean diff) — remove the
  matching `all/00-unattended-install-delete.yaml` override once done.
- Consider enabling `SecurityProfileConfig.workloadIsolation` (currently pinned `false` in
  `talos/all/03-security-profile.yaml` to match pre-migration behavior) — sandboxd workload
  isolation, `talosctl gen config`'s default for fresh Talos 1.14 configs. Watch for the documented
  LUKS/EPHEMERAL stuck-closing failure mode on the first reboot after enabling it.
