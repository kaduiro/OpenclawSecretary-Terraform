# VPS implementation boundary

This directory is the isolated implementation boundary introduced by `TASK-BASE-001`.

- `terraform/` owns VPS and Cloudflare IaC only.
- `ansible/` will own host configuration.
- `compose/` will own service composition.
- `policies/` stores machine-enforced boundary baselines.
- `tools/` and `runbooks/` will store execution and recovery procedures.

The existing repository root remains the GCP rollback source. Code under `vps/` must not reference root GCP modules or use the Google Terraform provider. No provider credentials, remote state, DNS change, plan against live state, or apply is authorized by this scaffold.

`TASK-BASE-001` remains `evidence_pending` until an authorized root GCP plan proves no live-state difference. Static file hashes and CI prove source separation only.
