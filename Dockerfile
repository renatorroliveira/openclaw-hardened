# ==============================================================================
# Dockerfile for OpenClaw on Node.js 24
# Self-hosted AI assistant gateway with security hardening
# ==============================================================================

FROM node:24-bookworm-slim AS base

# --------------------------------------------------------------------------
# 1. Install system-level dependencies and iptables
# --------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        curl \
        ca-certificates \
        git \
        python3 \
        ffmpeg \
        tini \
        iptables \
        iproute2 \
        tzdata \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------------
# 1b. Set timezone to America/Los_Angeles and hostname
# --------------------------------------------------------------------------
RUN cp /usr/share/zoneinfo/America/Los_Angeles /etc/localtime \
    && echo "America/Los_Angeles" > /etc/timezone \
    && echo "openclaw-hardened" > /etc/hostname

# --------------------------------------------------------------------------
# 2. Create a dedicated non-root user to run OpenClaw
# --------------------------------------------------------------------------
RUN groupadd --gid 1100 openclaw \
    && useradd --uid 1100 --gid openclaw --shell /bin/bash \
        --create-home openclaw

# --------------------------------------------------------------------------
# 3. Prepare OpenClaw directories with correct ownership
# --------------------------------------------------------------------------
RUN mkdir -p /home/openclaw/.openclaw/credentials \
             /home/openclaw/.openclaw/logs \
             /home/openclaw/workspace \
    && chown -R openclaw:openclaw /home/openclaw

# --------------------------------------------------------------------------
# 4. Install OpenClaw globally via npm
# --------------------------------------------------------------------------
RUN npm install -g openclaw@latest \
    && npm cache clean --force

# --------------------------------------------------------------------------
# 4b. Install AWS CLI v2 (for Bedrock credential verification/debugging)
# --------------------------------------------------------------------------
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
      URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"; \
    elif [ "$ARCH" = "aarch64" ]; then \
      URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"; \
    else \
      echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    curl -sL "$URL" -o /tmp/awscliv2.zip && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# --------------------------------------------------------------------------
# 5. (Optional) Install Playwright browsers for Browser Relay support
#    Uncomment the lines below if you need browser automation.
# --------------------------------------------------------------------------
RUN npx playwright install --with-deps chromium

# --------------------------------------------------------------------------
# 6. Bundle default config presets (deployed on first boot by entrypoint)
# --------------------------------------------------------------------------
COPY config/openclaw-config.apple-silicon.json5 /opt/openclaw/config.apple-silicon.json5
COPY config/openclaw-config.nvidia.json5 /opt/openclaw/config.nvidia.json5
COPY config/openclaw-config.windows-nvidia.json5 /opt/openclaw/config.windows-nvidia.json5
COPY config/openclaw-config.bedrock.json5 /opt/openclaw/config.bedrock.json5

# --------------------------------------------------------------------------
# 7. Configure iptables firewall rules
#
#    Policy:
#    - Allow all traffic on loopback (INPUT + OUTPUT)
#    - Allow incoming on port 18789 (Gateway Control UI / WebSocket)
#    - Allow outgoing only on ports 443 (HTTPS), 53 (DNS), and 11434 (Ollama)
#    - Allow return traffic for established/related connections
#      (both directions)
#    - Drop all other incoming AND outgoing traffic
#
#    This is written as an entrypoint script so the rules are applied at
#    container start (iptables needs NET_ADMIN capability at runtime).
# --------------------------------------------------------------------------
COPY --chown=openclaw:openclaw <<'SCRIPT' /usr/local/bin/apply-firewall.sh
#!/bin/bash
set -e

# Flush any pre-existing rules
iptables -F INPUT
iptables -F OUTPUT
iptables -F FORWARD

# Default policies — drop everything except explicitly allowed traffic
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# --- Loopback — allow all traffic on lo (INPUT + OUTPUT) ---
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# --- INPUT rules ---
# Allow return traffic from outgoing requests (stateful)
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Allow incoming Gateway Control UI / WebSocket (port 18789)
iptables -A INPUT -p tcp --dport 18789 -m conntrack --ctstate NEW -j ACCEPT

# --- OUTPUT rules ---
# Allow return traffic for incoming connections (stateful)
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Allow DNS resolution (UDP and TCP on port 53)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
# Allow outgoing connections to Ollama inference server (port 11434)
iptables -A OUTPUT -p tcp --dport 11434 -m conntrack --ctstate NEW -j ACCEPT
# Allow new outgoing HTTPS connections (port 443 only)
iptables -A OUTPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# Log and drop everything else (useful for debugging)
iptables -A INPUT  -j LOG --log-prefix "IPT-DROP-IN:  " --log-level 4
iptables -A INPUT  -j DROP
iptables -A OUTPUT -j LOG --log-prefix "IPT-DROP-OUT: " --log-level 4
iptables -A OUTPUT -j DROP

echo "[firewall] iptables rules applied successfully"
SCRIPT

RUN chmod +x /usr/local/bin/apply-firewall.sh

# --------------------------------------------------------------------------
# 8. Entrypoint script: apply firewall, deploy config, drop to non-root
# --------------------------------------------------------------------------
COPY <<'ENTRYPOINT_SCRIPT' /usr/local/bin/entrypoint.sh
#!/bin/bash
set -e

# Apply iptables rules (requires --cap-add=NET_ADMIN at docker run)
/usr/local/bin/apply-firewall.sh

# --- Unset empty AWS env vars (preserves SDK credential chain fallback) ---
# Docker Compose sets these to empty string when not configured in .env;
# an empty AWS_ACCESS_KEY_ID breaks the SDK's fallback to IMDS/instance roles.
for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
    eval "val=\${$var:-}"
    [ -z "$val" ] && unset "$var"
done

# --- Deploy default config on first boot ---
# Run as openclaw user since DAC_OVERRIDE is dropped (root can't write to openclaw-owned dirs)
CONFIG_FILE="/home/openclaw/.openclaw/openclaw.json"
if [ ! -f "$CONFIG_FILE" ]; then
    PRESET="${OPENCLAW_PRESET:-windows-nvidia}"
    gosu openclaw cp "/opt/openclaw/config.${PRESET}.json5" "$CONFIG_FILE"

    # Bedrock preset: substitute region placeholder (run as openclaw to preserve ownership)
    if [ "$PRESET" = "bedrock" ]; then
        REGION="${AWS_BEDROCK_REGION:-us-west-2}"
        gosu openclaw sed -i "s/\${AWS_BEDROCK_REGION}/${REGION}/g" "$CONFIG_FILE"
        echo "[entrypoint] Deployed Bedrock config (region: ${REGION})"
    else
        echo "[entrypoint] Deployed default config (preset: ${PRESET})"
    fi
fi

# Drop privileges and exec the main process as the openclaw user
exec gosu openclaw "$@"
ENTRYPOINT_SCRIPT

RUN chmod +x /usr/local/bin/entrypoint.sh

# Install gosu for reliable privilege de-escalation
RUN apt-get update && apt-get install -y --no-install-recommends gosu \
    && rm -rf /var/lib/apt/lists/* \
    && gosu nobody true

# --------------------------------------------------------------------------
# 9. Environment variables & metadata
# --------------------------------------------------------------------------
ENV HOME=/home/openclaw \
    XDG_CONFIG_HOME=/home/openclaw/.openclaw \
    NODE_ENV=production

# Expose Gateway Control UI / WebSocket port
EXPOSE 18789

# Persistent storage for config, credentials, logs, and workspace
VOLUME ["/home/openclaw/.openclaw", "/home/openclaw/workspace"]

# Signal that the root filesystem is designed to run read-only.
# Writable paths: the two VOLUMEs above + tmpfs mounts at runtime.
LABEL org.opencontainers.image.description="OpenClaw hardened gateway" \
      org.opencontainers.image.source="https://github.com/openclaw/openclaw" \
      security.read-only-root="true"

WORKDIR /home/openclaw

# --------------------------------------------------------------------------
# 10. Start OpenClaw gateway via tini (PID 1 reaping)
# --------------------------------------------------------------------------
ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["openclaw", "gateway", "run", "--allow-unconfigured"]
