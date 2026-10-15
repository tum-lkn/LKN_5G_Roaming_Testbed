# N4 (PFCP) IPsec — SMF ⇄ UPF

Protects the **N4 interface** (PFCP, UDP 8805) between the SMF and the UPF with
IPsec ESP in **tunnel mode**, IKEv2, X.509 certificate authentication — the same
3GPP NDS/IP profile the N9 tunnel (`docker/ipsectunnel/`) uses.

## Why it is split across two namespaces

On the VPLMN host the two N4 endpoints live in **different network namespaces**:

| Endpoint | Where it runs            | N4 address           | IKE role  |
|----------|--------------------------|----------------------|-----------|
| SMF      | `open5gs-smf` container  | `192.168.50.193`     | initiator |
| UPF      | host (`network_mode: host`) | `VPLMN_IP` (`:8805`) | responder |

So strongSwan terminates the SMF end **inside the SMF container** and the UPF end
**on the host**. The host runs a single `charon` that serves both the N9 tunnel
and the N4 conn (`n4-smf-upf`, `reqid=2`). The N4 conn is a drop-in at
`/etc/ipsec.d/n4-smf-upf.conf`, so `n4_ipsec.sh {start,stop}` toggles N4 without
touching N9.

## Requirements

1. **SMF image** must contain strongSwan — added in `docker/smf-docker/Dockerfile.smf`
   (`strongswan strongswan-pki libcharon-extra-plugins`). Rebuild after changing.
2. **SMF container** must have this cert package + scripts bind-mounted at
   `/n4-ipsec` (read-only) and keep its `NET_ADMIN` cap (already present):

   ```yaml
   # under open5gs-smf: in docker-compose.yml
   volumes:
     - ./docker/n4-ipsec/certs/smf:/n4-ipsec:ro
   ```
   `NET_ADMIN` alone is sufficient — the container does **not** need `privileged`.

## Usage

```bash
# one-time: generate certs, install on host + into the SMF, write configs
sudo ./n4_ipsec.sh deploy

# toggle the tunnel (what the WebUI button calls)
sudo ./n4_ipsec.sh start
sudo ./n4_ipsec.sh stop
sudo ./n4_ipsec.sh status

# switch the ESP cipher (mode 1-6) and restart N4 only (N9 untouched)
sudo ./n4_ipsec.sh cipher 2       # -> AES-256-GCM
sudo ./n4_ipsec.sh esp-status     # print the currently-configured esp=
```

`start` re-applies the SMF-side config every time because container filesystem
changes made via `docker exec` do **not** survive a container restart; the host
side persists in `/etc/ipsec.d`.

## ESP cipher mode

This N4 tunnel is **fully self-contained on one host** (SMF container + host
UPF), so it can run a different ESP cipher from the *other* PLMN's N4 **and**
from N9. The cipher is chosen by mode number (same numbering as N9's
`esp_config.sh`):

| Mode | ESP proposal        | |
|------|---------------------|--|
| 1    | `aes128gcm16`       | AES-128-GCM (AEAD, default) |
| 2    | `aes256gcm16`       | AES-256-GCM (AEAD) |
| 3    | `aes128-sha256`     | AES-128-CBC + HMAC-SHA256 |
| 4    | `aes256-sha256`     | AES-256-CBC + HMAC-SHA256 |
| 5    | `null-sha256`       | ⚠️ NULL + SHA256 — **no encryption** |
| 6    | `null-aes128gmac`   | ⚠️ NULL + GMAC — **no encryption** |

`cipher N` persists the choice in `.n4_esp_mode`, threads it into **both** ends
(they are regenerated on every `start`, so it is re-applied via `--esp <proposal>`
rather than edited in place), then does an N4-only stop+start. The WebUI IPsec
tab exposes this per PLMN (VPLMN locally, HPLMN over SSH via the backend), so all
three tunnels — N9, N4·VPLMN, N4·HPLMN — show and set their cipher independently.

## Verify encryption is active

```bash
# generate N4 traffic (SMF re-associates with the UPF), then:
sudo ./n4_ipsec.sh status                       # look for ESTABLISHED / INSTALLED
sudo tcpdump -ni any esp and host 192.168.50.193   # PFCP now rides inside ESP
```

## Files

| File | Runs on | Purpose |
|------|---------|---------|
| `01_setup_n4_ca.sh` | host | issue `smf-n4` + `upf-n4` certs (reuses the N9 CA if its key matches its cert, else a dedicated N4 CA) |
| `certs/smf/install_certs_smf.sh` | SMF ctr | install certs into the container's `/etc/ipsec.d` |
| `certs/smf/setup_ipsec_smf.sh` | SMF ctr | write config, start charon, bring N4 up (initiator) |
| `certs/host/install_certs_host.sh` | host | install UPF N4 certs on the host |
| `certs/host/setup_ipsec_n4_host.sh` | host | write the `n4-smf-upf.conf` drop-in, reload charon (responder) |
| `n4_ipsec.sh` | host | orchestrator: `deploy` / `start` / `stop` / `status` / `cipher N` / `esp-status` |
