# B580-proxy

An nginx reverse proxy for the two [B580-ai](../B580-ai) Strata servers, with
automatic Let's Encrypt certificates and API-key authentication.

```
Internet
  │
  ├─ https://b580.example.com:443   ──► 127.0.0.1:8080   (GPU 1)
  └─ https://b580.example.com:8443  ──► 127.0.0.1:8081   (GPU 2)
```

One domain can serve both ports, or a second domain can be used for the second
port.  **One API key works on both ports**, whichever model is running:

```sh
curl -H 'X-API-Key: <api-key>' https://b580.example.com:443/v1/models
# ...or:
curl -H 'Authorization: Bearer <api-key>' https://b580.example.com:8443/v1/models
```

Missing or wrong keys get `401` with `WWW-Authenticate: Bearer`.  The key is
never forwarded to Strata, and the proxy logs do not contain headers.

When only one server is running — single-GPU or layer-split mode — the B580-ai
panel relays internal `127.0.0.1:8081` to `127.0.0.1:8080`.  nginx itself uses
fixed backends, so port 8443 still reaches the one running model with the same
key.  Starting GPU 2 frees 8081 for its real Strata server and the relay steps
aside.

The panel's **Open dashboard** links stay local (`8080` / `8081`) because a
browser cannot attach an API-key header.  The public ports are for API clients.

---

## Requirements

- Ubuntu/Debian with `systemd` (tested on Ubuntu 26.04).
- A DNS name (or two) whose A/AAAA record points at this machine's public IP.
- Router forwarding:
  - TCP **80** → this machine (HTTP-01 certificate challenge),
  - TCP **443** and **8443** (or whichever two ports you choose) → this machine.
- `sudo` access; the installer adds one tightly scoped sudoers rule.

> **Why port 80?** Let's Encrypt confirms control of the domain by fetching a
> token from `http://<domain>/.well-known/acme-challenge/...`.  After a
> certificate is issued, port 80 only redirects to HTTPS.

---

## Install

From this directory:

```sh
sudo ./install.sh
```

The installer:

- installs `nginx`, `certbot` and `openssl`;
- installs the privileged helper at `/usr/local/libexec/b580-proxy` and the
  user wrapper at `/usr/local/bin/b580-proxy`;
- allows only your user to run that one helper through `sudo` without a
  password (`/etc/sudoers.d/b580-proxy`);
- adds a certbot deploy hook that reloads nginx after a renewal;
- enables the certbot renewal timer;
- disables Ubuntu's default nginx site (backup remains in
  `/etc/nginx/sites-available/default`) and leaves nginx stopped until the
  proxy is enabled;
- allows 80/443/8443 through `ufw` if `ufw` is active. If you choose other public ports,
  install with `sudo ./install.sh --ports "80 443 9443"` (or open them yourself).

It does **not** enable the proxy or request a certificate.  That happens when
you save the settings in B580-ai, or with `b580-proxy apply`.

---

## Configure from the B580-ai panel

Open <http://localhost:9090> and use the **Public access** section:

1. Enter the primary domain and the Let's Encrypt email.
2. Leave **Second domain** empty for one certificate on two ports, or enter a
   second name to use it for port 8443.
3. Set the two public ports (defaults 443 and 8443).
4. Press **Save & enable**.
5. Under **API key**, use **Generate new key** and store the value.  It is
   shown once; only the last four characters and a fingerprint are displayed
   later.  If no key exists yet, the first **Save & enable** generates one.
   If an older install has two keys, the old primary key is kept and the
   secondary one is discarded.
6. Press **Disable** to stop nginx and free the ports; enable it again with
   **Save & enable**.

The first enable call runs certbot and can take up to a minute while Let's
Encrypt validates the domain.  Errors (DNS, port 80, rate limits) are shown in
the panel and in `/etc/b580-proxy/last-error`.

Settings are stored in B580-ai's `config.json` under `"proxy"`:

```json
"proxy": {
  "enabled": false,
  "domain": "",
  "domain2": "",
  "port": 443,
  "port2": 8443,
  "email": "",
  "staging": false
}
```

The API keys are **not** in `config.json`; they live in
`/etc/b580-proxy/api-keys.json` (mode 0600).  The legacy
`/etc/b580-proxy/api.key` is kept in sync with the primary key for rollback.

---

## Command line

The same operations are available from a shell:

```sh
b580-proxy status
b580-proxy apply --domain b580.example.com --email you@example.com
b580-proxy apply --domain b580.example.com --domain2 gpu2.example.com \
                 --port 443 --port2 8443 --email you@example.com
b580-proxy disable
b580-proxy rotate-key              # new key for both ports
b580-proxy set-key                 # prompt for a custom key for both ports
b580-proxy renew                   # run certbot renew now
b580-proxy renew --force           # force a new certificate (rate limits!)
b580-proxy logs
```

From the sibling project:

```sh
cd /home/oliver/B580-ai
./proxy down          # = b580-proxy disable
./proxy up            # = b580-proxy enable (uses saved settings)
./proxy status
```

`B580-ai/proxy` is only a convenience wrapper around `b580-proxy`.

### OpenCode client

OpenCode sends its credential as `Authorization: Bearer <key>`.  The option is
called `apiKey` (camel case), and in V2 it belongs under `settings`:

```jsonc title="opencode.jsonc"
{
  "$schema": "https://opencode.ai/config.json",
  "model": "b580/qwen3.8-flash-next-iq3_s",
  "providers": {
    "b580": {
      "name": "B580 GPU 1",
      "env": ["B580_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": {
        "baseURL": "https://owacoder.com:443/v1"
      },
      "models": {
        "qwen3.8-flash-next-iq3_s": {
          "name": "Qwen3.8 Flash Next IQ3_S"
        }
      }
    }
  }
}
```

Set `B580_API_KEY` to the proxy API key.  The same key works on
`https://owacoder.com:443/v1` and `https://owacoder.com:8443/v1`; point
`baseURL` at whichever port you want to use.  `api_key` is not a valid option
name; using it makes OpenCode send no credential and the proxy returns
`{"error":"API key required"}`.

---

## Certificates and renewal

- Initial issuance: `certbot certonly --webroot` against
  `/var/www/b580-proxy`, cert-name `b580-proxy`.
- Renewal: the distro's `certbot.timer` runs twice a day; certbot renews when
  fewer than 30 days remain.
- Reload: `/etc/letsencrypt/renewal-hooks/deploy/b580-proxy-reload` tests and
  reloads nginx after a successful renewal.
- A staging certificate uses the separate cert-name `b580-proxy-staging`, so
  it cannot overwrite the production certificate.  Turn staging off and press
  Save & enable to switch to a trusted certificate.
- Apply also triggers renewal when the certificate has fewer than 30 days
  left, so re-enabling after a long pause refreshes it.

Check the timer:

```sh
systemctl status certbot.timer
sudo certbot certificates
b580-proxy status
```

---

## Disable / uninstall

```sh
b580-proxy disable
```

This removes the nginx site symlink, runs `systemctl disable --now nginx`, and
keeps the certificate, key and settings.  Ports 80/443/8443 are free again.
`b580-proxy enable` re-applies the saved settings.

To remove the generated nginx config (certificates are kept):

```sh
sudo /usr/local/libexec/b580-proxy uninstall
```

Full removal by hand:

```sh
sudo /usr/local/libexec/b580-proxy uninstall
sudo rm -f /usr/local/bin/b580-proxy /usr/local/libexec/b580-proxy \
           /etc/sudoers.d/b580-proxy
sudo rm -rf /etc/b580-proxy /etc/nginx/b580-proxy /var/www/b580-proxy
sudo apt remove nginx certbot        # optional
```

---

## Files

| Path | Purpose |
| --- | --- |
| `/etc/b580-proxy/settings.json` | Last applied domains, ports, email, staging |
| `/etc/b580-proxy/api-keys.json` | The one API key (0600 root) |
| `/etc/b580-proxy/api.key` | Legacy mirror of that key (0600 root) |
| `/etc/b580-proxy/last-error` | Last certbot error, shown in the panel |
| `/etc/nginx/b580-proxy/api-key.conf` | Auth snippet included by both HTTPS servers |
| `/etc/nginx/sites-available/b580-proxy.conf` | Generated site config |
| `/etc/nginx/sites-enabled/b580-proxy.conf` | Symlink, removed by `disable` |
| `/var/www/b580-proxy` | ACME HTTP-01 webroot |
| `/etc/letsencrypt/live/b580-proxy*` | Issued certificates |
| `/usr/local/libexec/b580-proxy` | Privileged helper |
| `/usr/local/bin/b580-proxy` | User wrapper (`sudo -n` to the helper) |

Nginx configs are generated; edit the panel or use `apply`, not the config file.

---

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `Save & enable` says certbot failed | DNS A/AAAA points here, router forwards TCP 80, `curl http://<domain>/.well-known/acme-challenge/test` reaches nginx. See `/etc/b580-proxy/last-error`. |
| `502 Bad Gateway` with a valid key | For port 443, no Strata service is listening on 8080. For port 8443, 8081 is not listening — start GPU 2, or start the single/split model with the B580-ai panel (its internal relay covers 8081). |
| `403 Forbidden` from Strata with `Host '…' is not allowed` | The dashboard domain is missing from the model's `allowed_hosts`. Press **Save & enable** again, then restart the Strata services so the regenerated config is loaded. |
| `401` for a request that has a key | Use the proxy key. Header must be `X-API-Key: <key>` or `Authorization: Bearer <key>`. Rotate it in the panel if it was lost; the new key works on both ports. |
| Browser dashboard fails through the proxy | Expected: public access requires a header. Use `http://localhost:8080/` or `:8081/` locally. |
| `nginx -t` fails | Read `/etc/b580-proxy/last-error`, `b580-proxy logs`, and `journalctl -u nginx`. |
| `could not build map_hash, you should increase map_hash_bucket_size: 64` | An older helper embedded the API key in an nginx map regex. Re-run `sudo /home/oliver/B580-proxy/install.sh` to install the fixed helper, then press **Save & enable** again. The fix uses short map keys and exact string checks, so it also works with 128-character keys. |
| Renewal does not happen | `systemctl status certbot.timer`; nginx must be running for the HTTP-01 renewal. Re-enable the proxy before the certificate expires. |
| Panel shows "helper is not installed" | Run `sudo /home/oliver/B580-proxy/install.sh`, then restart the panel. |
| Ports still busy after disable | `ss -ltnp 'sport = :443'`; another nginx site or service may be using them. |
