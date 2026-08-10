#!/usr/bin/env bash
# Validates that a standalone EC2 instance (booted from a candidate EKS node
# AMI) has the components needed to join an EKS cluster. Run on the instance
# itself via SSM session — no cluster join is performed by this script.
set -uo pipefail

PASS=0; FAIL=0; SKIP=0
pass() { printf "  [PASS] %s\n" "$1"; ((++PASS)); }
fail() { printf "  [FAIL] %s\n" "$1"; ((++FAIL)); }
skip() { printf "  [SKIP] %s\n" "$1"; ((++SKIP)); }
header() { printf "\n=== %s ===\n" "$1"; }

# ── OS / kernel basics ───────────────────────────────────────────────
header "OS"
cat /etc/os-release 2>/dev/null | grep -E '^(NAME|VERSION)='
uname -r

# ── SSM agent (you're on the box, but confirm it's a real install) ──
header "SSM Agent"
if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
  pass "amazon-ssm-agent is active"
else
  fail "amazon-ssm-agent is not an active systemd service"
fi

# ── IMDSv2 reachability (matches EC2NodeClass httpTokens=required) ──
header "Instance Metadata (IMDSv2)"
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
if [[ -n "$TOKEN" ]]; then
  pass "IMDSv2 token issued"
  ROLE=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
  [[ -n "$ROLE" ]] && pass "instance profile attached: $ROLE" || fail "no IAM role on instance profile"
else
  fail "could not obtain IMDSv2 token"
fi

# ── Bootstrap mechanism: nodeadm (AL2023-style) vs legacy bootstrap.sh ──
header "Bootstrap mechanism"
if command -v nodeadm >/dev/null 2>&1; then
  pass "nodeadm present: $(nodeadm version 2>&1 | head -1)"
  BOOTSTRAP_STYLE=nodeadm
elif [[ -x /etc/eks/bootstrap.sh ]]; then
  pass "/etc/eks/bootstrap.sh present"
  BOOTSTRAP_STYLE=bootstrap.sh
else
  fail "neither nodeadm nor /etc/eks/bootstrap.sh found — AMI cannot self-bootstrap"
  BOOTSTRAP_STYLE=none
fi
[[ -d /etc/eks ]] && pass "/etc/eks directory present" || fail "/etc/eks directory missing"

# ── Core runtime components ──────────────────────────────────────────
header "Container runtime / kubelet"
for bin in kubelet containerd containerd-shim-runc-v2 runc; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "$bin: $(command -v "$bin")"
  else
    fail "$bin not found on PATH"
  fi
done

for svc in kubelet containerd; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}.service"; then
    pass "${svc}.service unit exists (state: $(systemctl is-enabled ${svc} 2>&1))"
  else
    fail "${svc}.service unit not installed"
  fi
done

# ── CNI ───────────────────────────────────────────────────────────────
header "CNI"
if [[ -d /opt/cni/bin ]] && [[ -n "$(ls -A /opt/cni/bin 2>/dev/null)" ]]; then
  pass "/opt/cni/bin populated: $(ls /opt/cni/bin | tr '\n' ' ')"
else
  fail "/opt/cni/bin missing or empty"
fi

# ── ECR credential provider (needed to pull kube-system images) ─────
header "Image credential provider"
if [[ -x /etc/eks/image-credential-provider/ecr-credential-provider ]]; then
  pass "ecr-credential-provider present"
else
  skip "ecr-credential-provider not found at expected path — check AMI's actual path"
fi

# ── Kernel modules / sysctls kubelet expects ─────────────────────────
header "Kernel prerequisites"
for mod in overlay br_netfilter; do
  if lsmod | grep -q "^${mod}" || modinfo "$mod" >/dev/null 2>&1; then
    pass "kernel module available: $mod"
  else
    fail "kernel module unavailable: $mod"
  fi
done

ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "ERR")
[[ "$ip_fwd" == "1" ]] && pass "net.ipv4.ip_forward=1" || fail "net.ipv4.ip_forward=${ip_fwd} (expected 1)"

# ── FIPS host state (this project requires FIPS-validated compute) ──
header "FIPS"
fips_val=$(cat /proc/sys/crypto/fips_enabled 2>/dev/null || echo "ERR")
if [[ "$fips_val" == "1" ]]; then
  pass "/proc/sys/crypto/fips_enabled=1"
else
  fail "/proc/sys/crypto/fips_enabled=${fips_val} (expected 1)"
fi
if command -v fips-mode-setup >/dev/null 2>&1; then
  fips-mode-setup --check >/dev/null 2>&1 && pass "fips-mode-setup --check" || fail "fips-mode-setup --check failed"
else
  skip "fips-mode-setup not present"
fi

# ── Network path to the EKS control plane / AWS APIs ─────────────────
# Fill these in from `aws eks describe-cluster` before running.
header "Network reachability"
: "${EKS_API_ENDPOINT:=}"   # e.g. https://ABCD1234.gr7.us-east-1.eks.amazonaws.com
if [[ -n "$EKS_API_ENDPOINT" ]]; then
  host=$(echo "$EKS_API_ENDPOINT" | sed -E 's#https?://##;s#/.*##')
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/443" 2>/dev/null; then
    pass "TCP 443 reachable: $host"
  else
    fail "TCP 443 NOT reachable: $host (check SG/route/NAT — this alone explains a failed join)"
  fi
else
  skip "EKS_API_ENDPOINT not set — export it and re-run to test control-plane connectivity"
fi

for ep in ec2 sts logs ecr.api ecr.dkr; do
  host="${ep}.${AWS_REGION:-$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null)}.amazonaws.com"
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${host}/443" 2>/dev/null; then
    pass "TCP 443 reachable: $host"
  else
    fail "TCP 443 NOT reachable: $host"
  fi
done

echo ""
echo "========================================"
printf "PASS: %d  FAIL: %d  SKIP: %d\n" "$PASS" "$FAIL" "$SKIP"
echo "========================================"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
