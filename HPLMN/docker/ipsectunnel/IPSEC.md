# IPsec Tunnel for N9 Interface

The IPsec documentation lives in a single canonical location to avoid drift:

**➡️ [docs/IPSEC.md](../../../docs/IPSEC.md)**

It covers the overview, directory layout, the automated `deploy_ipsec.sh`
orchestrator, the manual step-by-step setup, ESP algorithm modes, verification,
and troubleshooting for the optional N9 GTP-U tunnel between the VPLMN and HPLMN
UPFs (Home Routed roaming mode).

The scripts in this directory — `01_setup_ca.sh`, the `ipsec_certificates/pc*/`
`02_*`/`03_*` scripts, and `update_ipsec_ips.sh` — are the ones that guide
references. See it for how they fit together.
