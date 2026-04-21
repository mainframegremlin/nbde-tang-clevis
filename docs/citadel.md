# Citadel: Tang Server

Citadel is a server running Docker and Portainer. It hosts the Tang key server that all LUKS
clients on the network bind to. The Tang service runs as a container managed by a Portainer
stack, with keys stored in a named Docker volume so they persist across container restarts and
image updates.

---

## Prerequisites

- Docker and Portainer are already installed on Citadel
- Citadel is reachable at `10.0.0.10` from all LUKS clients
- Port `1234` is open on Citadel's firewall for inbound TCP from LUKS client IPs

---

## Portainer Stack Definition

In the Portainer UI, create a new stack named `tang` and paste the following compose definition:

```yaml
services:
  tang:
    image: padhihomelab/tang:latest
    container_name: tang
    restart: unless-stopped
    ports:
      - "1234:8080"
    volumes:
      - tang-keys:/var/db/tang

volumes:
  tang-keys:
```

Deploy the stack. The Tang server will start and generate its key pair on first boot, storing
them in the `tang-keys` volume.

---

## Verifying the Service

```bash
# From Citadel itself
curl http://localhost:1234/adv

# From another machine on the LAN
curl http://10.0.0.10:1234/adv
```

A successful response is a JSON document containing the Tang server's advertisement (public key
info). If you get a connection refused or timeout, check that the stack is running and port 1234
is not blocked.

---

## Firewall

Allow inbound TCP on port 1234 from your LUKS client IPs. Example using `ufw`:

```bash
# Allow Bastion
sudo ufw allow from 10.0.0.20 to any port 1234 proto tcp

# Allow Rampart (if using a static IP or DHCP reservation)
sudo ufw allow from <Rampart-ip> to any port 1234 proto tcp

sudo ufw reload
```

If Citadel uses a hardware firewall or router ACLs instead of ufw, apply the equivalent rules
there.

---

## Updating the Tang Image

Because keys live in the `tang-keys` volume (not in the container), pulling a new image and
redeploying the stack is safe. The keys are preserved.

```bash
docker pull padhihomelab/tang:latest
# Then redeploy the stack in Portainer (Pull and redeploy)
```

After redeployment, verify the advertisement is still being served:

```bash
curl http://10.0.0.10:1234/adv
```

If the keys changed (only possible if the volume was wiped), all clients must be rebound. See [recovery.md](recovery.md) for key rotation procedure.
