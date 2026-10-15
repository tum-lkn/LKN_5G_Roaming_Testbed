# Post-Quantum IKEv2 Performance Testbed — Docker Edition

Dockerized version of the two-VM strongSwan testbed for measuring IKEv2
handshake performance with post-quantum cryptography (ML-KEM key exchange,
ML-DSA authentication). The two VMs (PC1/VPLMN initiator, PC2/HPLMN
responder) become two containers on a dedicated bridge network, keeping the
original certificate identities, the four test scenarios, the pcap-based
timing extraction, the result filename pattern, and the JSON output schema —
so the testbed WebUI keeps working with the results.

## Layout

```
pq-ike-docker/
├── README.md
├── .env                     # subnet / IPs / strongSwan ref (edit here)
├── docker-compose.yml       # pq-vplmn + pq-hplmn + one-shot cert generator
├── Dockerfile               # builds strongSwan from source (2-stage)
├── ike_eval_docker.sh       # the evaluation orchestrator (runs on the host)
└── container/
    ├── strongswan.conf      # charon file logging (µs precision)
    ├── entrypoint.sh
    ├── swan-start           # start charon + swanctl --load-all
    ├── swan-stop            # stop charon + flush XFRM state
    ├── swan-run-initiator   # timed run: charon start → INSTALLED (in-container)
    └── gen-certs            # RSA + ML-DSA-65 PKI generator
```

Created at runtime: `./conf/` (swanctl config + certs per container),
`./results/{json,pcaps,logs}`, and an `ike_pq_results -> results/json`
symlink for WebUI-backend compatibility.

## Network

The containers use **192.168.40.0/24** (vplmn = .55, hplmn = .230,
gateway = .1) — deliberately different from the lab network so the testbed
can run on one of the lab VMs without any routing collision. Certificate identities (the 3GPP UPF DNs) are unchanged
from the VM setup; only the IP-address SANs follow the new subnet. All four
values live in `.env`; change them there if 192.168.40.0/24 is taken on
your host (`ip a | grep 192.168.40`).

## Requirements

A native Linux host with Docker Engine and Compose v2. IPsec runs in the
host kernel (containers share it); any stock distro kernel works. If
CHILD_SA installation ever fails with a missing-algorithm error, load the
modules once on the host: `sudo modprobe esp4 xfrm_user`. The image build
needs network access to github.com and the Debian mirrors and takes about
5–10 minutes.

## Quick start

```bash
docker compose build              # compile strongSwan (ml-dsa branch, OpenSSL 3.5)
docker compose run --rm certs     # generate RSA + ML-DSA-65 PKI into ./conf/
docker compose up -d              # start pq-vplmn (.55) and pq-hplmn (.230)
```

> **Snap-confined docker?** `docker compose build` exits 1 with
> `open /tmp/.tmp-compose-build-metadataFile-...: no such file or directory`
> — compose writes that metadata file to a hardcoded `/tmp` path it then can't
> read back from the snap's private `/tmp` (`TMPDIR` and `COMPOSE_BAKE=false`
> don't help). The image builds fine; only the exit code is wrong. Use plain
> `docker build` instead — the WebUI's **Build image** button already does:
> ```bash
> docker build -t pq-ike-strongswan:local --build-arg SWAN_REF=ml-dsa .
> ```
> `run --rm certs`, `up -d` and `down` are unaffected.

```bash
./ike_eval_docker.sh 5 30         # all 4 scenarios, 30 iterations, no delay
./ike_eval_docker.sh 5 30 10      # same, with +10 ms netem each way (+20 ms RTT)
./ike_eval_docker.sh 4 50         # only fully-PQ scenario, 50 iterations
```

Scenarios: 1 = ECP-256 + RSA, 2 = ML-KEM-768 + RSA, 3 = ECP-256 + ML-DSA-65,
4 = ML-KEM-768 + ML-DSA-65, 5 = all four. Results land in
`results/json/<timestamp>_<delaylabel>_ike_<config>.json` (also visible via
the `ike_pq_results/` symlink), packet captures in `results/pcaps/`,
per-iteration SA dumps and tcpdump logs in `results/logs/`. Each container's
charon log: `docker exec pq-vplmn cat /var/log/strongswan/charon.log`.

If the image is already built but the containers are down (e.g. after a
reboot), the orchestrator starts them itself via `docker compose up -d`.

## How the VM setup maps to containers

| VM testbed                         | Docker testbed                                  |
|------------------------------------|-------------------------------------------------|
| PC1 / VPLMN VM (initiator)         | container `pq-vplmn` (192.168.40.55)             |
| PC2 / HPLMN VM (responder)         | container `pq-hplmn` (192.168.40.230)            |
| `systemctl start/stop strongswan`  | `swan-start` / `swan-stop` via `docker exec`     |
| `ssh roaming@PC2 "sudo …"`         | `docker exec pq-hplmn …`                         |
| `tc netem` + per-peer filter       | plain `tc netem` on each container's `eth0` (the dedicated bridge carries only peer traffic; `docker exec` is unaffected) |
| tcpdump/tshark on PC1              | tcpdump/tshark inside `pq-vplmn` on `eth0`       |
| wall clock: `systemctl start` → INSTALLED | measured inside the container by `swan-run-initiator`, so `docker exec` latency never pollutes it |

The swanctl.conf generator, the tshark+awk wire-timing extraction (including
the fallback for IP-fragmented SA_INIT messages) and the JSON schema are
verbatim from the original script. Two small fixes: the JSON
`authentication` field now reports the real auth algorithm per scenario
(`rsa` / `mldsa65`; it was hard-coded `ecdsa`), and `strongswan_version` is
detected at runtime.

## Why the image builds the `ml-dsa` branch

ML-KEM key exchange is in every strongSwan 6.0.x release (via OpenSSL 3.5+
since 6.0.2, plus strongSwan's built-in `ml` plugin). ML-DSA certificates
and IKEv2 PQ authentication, however, are **not in any 6.0.x release** (the
latest is 6.0.6, April 2026) — they live in the upstream `ml-dsa` branch,
planned for 6.1.0. A build of that branch identifies itself as 6.0.x, which
is why a "6.0.4 with ML-DSA" testbed is in practice a branch build; this
image reproduces that. The base image is Debian 13 (trixie), whose OpenSSL
3.5 provides both ML-KEM and ML-DSA to strongSwan's `openssl` plugin.

To pin an official release instead (scenarios 1 + 2 only — `pki` will have
no `mldsa65` key type), set `SWAN_REF=6.0.4` in `.env` and rebuild with
`docker compose build --no-cache` (or, on snap docker, `docker build --no-cache
-t pq-ike-strongswan:local --build-arg SWAN_REF=6.0.4 .`).

## Measurement notes

Both containers share one host: the bridge RTT is ~0.05 ms and the CPUs are
shared, so absolute numbers will differ from the two-VM testbed. The
relative comparison across the four scenarios — which is what isolates the
ML-KEM and ML-DSA overheads — remains valid, and the wire timings still
come from real packets on a real (veth) link, including genuine IP
fragmentation of large ML-KEM/ML-DSA payloads at the 1500-byte MTU. Use the
`delay_ms` argument to emulate network distance; verify with the RTT that
the script prints. Pin the containers to dedicated cores
(`docker update --cpuset-cpus`) if you want to reduce scheduling noise.

## Integrating with the testbed WebUI (backend.py v2.3)

The orchestrator is built to be driven by the existing `pq_eval` job flow
(`/api/pq/run`, `/api/pq/results`, websocket streaming, Cancel):

* same CLI contract: `<config 1-5> [iterations] [delay_ms]`, runs fine under
  `sudo -n stdbuf -oL -eL bash …` over `ssh -tt`;
* same result filenames (`YYYYmmdd-HHMMSS_<nodelay|delayXms>_ike_<config>.json`)
  and JSON schema, so the frontend's run grouping, charts, and parsed view
  work as-is;
* `ike_pq_results/` symlink → the backend's default `results_subdir` finds
  the JSONs without code changes;
* a SIGHUP trap → when the backend cancels the job (SSH teardown), netem,
  tcpdump, and charon are cleaned up in both containers;
* symlink-safe self-location → you may expose it as `~/ike_eval.sh`.

**Option A — small backend edit (recommended).** In `CONFIG["post_quantum"]`
set `host` to the Docker host and put the orchestrator first in
`script_path_candidates` (use an absolute path, since `~` is expanded on the
backend machine):

```python
"post_quantum": {
    "host": "<docker-host-ip>",
    "user": "roaming",
    "script_path_candidates": [
        "/home/roaming/pq-ike-docker/ike_eval_docker.sh",
        # ...existing entries can stay as fallbacks...
    ],
    "results_subdir": "ike_pq_results",   # unchanged (symlink handles it)
},
```

and in `ScriptJobManager.cancel_job()` widen the kill pattern so it matches
this script's name too, plus a container-side sweep:

```python
"sudo -n pkill -f ike_eval 2>/dev/null; "
"sudo -n docker exec pq-vplmn pkill -x tcpdump 2>/dev/null; "
"sudo -n docker exec pq-vplmn swan-stop 2>/dev/null; "
"sudo -n docker exec pq-hplmn swan-stop 2>/dev/null; "
"sudo -n docker exec pq-vplmn tc qdisc del dev eth0 root 2>/dev/null; "
"sudo -n docker exec pq-hplmn tc qdisc del dev eth0 root 2>/dev/null; "
"true"
```

**Option B — zero backend-code change.** On the Docker host create:

```bash
ln -s /home/roaming/pq-ike-docker/ike_eval_docker.sh /home/roaming/ike_eval.sh
ln -s /home/roaming/pq-ike-docker/results/json       /home/roaming/ike_pq_results
```

The existing candidate `~/ike_eval.sh` then resolves, the existing
`pkill -f ike_eval.sh` cancel pattern matches the symlinked command line,
and results are found at `~/ike_pq_results`. Only `host` (and `user`) in
`CONFIG["post_quantum"]` need to point at the Docker host.

Either way, the backend's prerequisites still apply: key-based SSH from the
backend VM (`ssh-copy-id roaming@<docker-host>`) and passwordless sudo on
the Docker host (`roaming ALL=(ALL) NOPASSWD: ALL` via `visudo`). No
frontend changes are needed.

## Customization

Network and build settings live in `.env` (subnet, both IPs, `SWAN_REF`).
The certificate generator accepts environment overrides, e.g.:

```bash
docker compose run --rm -e RSA_BITS=3072 certs
```

(`RSA_BITS` defaults to 2048; CA is RSA-3072 / ML-DSA-65; lifetimes via
`CA_LIFETIME`/`EE_LIFETIME` in days; DNs via `PC1_DN`/`PC2_DN`.) The pause
between iterations is `DELAY_BETWEEN` (default 5 s):
`DELAY_BETWEEN=2 ./ike_eval_docker.sh 5 30`.

## Troubleshooting

**Containers won't start** — `docker compose up -d`, then
`docker compose ps` and `docker logs pq-vplmn`. **Subnet collision** — pick
another subnet/IP set in `.env`, then `docker compose down && docker compose
up -d` (the eval script reads the same `.env`). **ML_KEM not available** —
`docker exec pq-vplmn openssl version` should report 3.5.x; rebuild with
`--no-cache`. **ML-DSA missing / scenarios 3–4 fail** — the image was built
from a release tag; set `SWAN_REF=ml-dsa`, rebuild, and re-run
`docker compose run --rm certs`. **PQ certs missing** —
`docker compose run --rm certs`. **`results/` not writable** — created
root-owned by an earlier run: `sudo chown -R $USER results/`. **Handshake
fails** — read both charon logs; `docker exec pq-vplmn swanctl --list-conns`
shows what was loaded. **ESP install error** — on the host:
`sudo modprobe esp4 xfrm_user`.

## Cleanup

```bash
docker compose down            # stop and remove containers + network
rm -rf conf results            # optionally wipe PKI and measurements
```
