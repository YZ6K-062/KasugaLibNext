#!/usr/bin/env bash
# setup-wsl-runner.sh - set up a Linux GitHub Actions runner inside WSL on the
# Surface, with the IA-64 cross toolchain installed from the offline bundle.
#
# Run this INSIDE WSL (not in Windows PowerShell):
#   bash /mnt/c/runner/setup-wsl-runner.sh -t <REGISTRATION_TOKEN>
#
# Typical token: repo -> Settings -> Actions -> Runners -> New self-hosted runner
#               (copy the --token value; valid ~1 hour)
#
# What it does
#   1. preflight: x86_64, glibc >= 2.38, systemd presence
#   2. apt-installs python3 cmake ninja git xz-utils
#   3. finds the offline bundle (kasuga-ia64-toolchain-*.tar.xz), unpacks to /opt
#   4. verifies the cross compiler actually runs
#   5. downloads actions-runner (linux-x64), configures with label ia64-cross
#   6. installs it as a systemd service when systemd is available in WSL
#
# IMPORTANT: the toolchain binaries need GLIBC >= 2.38.
#   OK  : Debian 13 (2.41), Ubuntu 24.04 (2.39)
#   FAIL: Debian 12 (2.36), Ubuntu 22.04 (2.35)
# If your distro is too old, install Debian 13 or Ubuntu 24.04 in WSL:
#   wsl --install -d Debian        (or: wsl --install -d Ubuntu-24.04)

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/YZ6K-062/KasugaLibNext}"
LABELS="${LABELS:-ia64-cross}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-wsl}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
BUNDLE_DEST="${BUNDLE_DEST:-/opt}"
BUNDLE_FILE="${BUNDLE_FILE:-}"
TOKEN="${TOKEN:-}"
INSTALL_SERVICE=1

usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  -t, --token TOKEN     registration token (or set TOKEN env)
  -n, --name NAME       runner name          (default: <hostname>-wsl)
  -l, --labels LABELS   extra labels         (default: ia64-cross)
  -b, --bundle FILE     path to the .tar.xz  (auto-detected when omitted)
  -d, --dir DIR         runner install dir   (default: ~/actions-runner)
      --no-service      do not install a systemd service
  -h, --help            this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--token)   TOKEN="$2"; shift 2 ;;
        -n|--name)    RUNNER_NAME="$2"; shift 2 ;;
        -l|--labels)  LABELS="$2"; shift 2 ;;
        -b|--bundle)  BUNDLE_FILE="$2"; shift 2 ;;
        -d|--dir)     RUNNER_DIR="$2"; shift 2 ;;
        --no-service) INSTALL_SERVICE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# sudo is absent in root-only environments (containers, some VMs, WSL root).
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    die "not root and sudo is unavailable; run as root or install sudo"
fi

# --------------------------------------------------------------- preflight --
step "Preflight"
[[ "$(uname -m)" == "x86_64" ]] || die "need an x86_64 WSL distro, got $(uname -m)"

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    echo "  distro : ${PRETTY_NAME:-unknown}"
fi

GLIBC_VER="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
echo "  glibc  : ${GLIBC_VER:-unknown}"
[[ -n "$GLIBC_VER" ]] || die "cannot determine glibc version"
# Compare major.minor against 2.38
if ! awk -v v="$GLIBC_VER" 'BEGIN{
        split(v,a,"."); if (a[1]+0 > 2) exit 0;
        if (a[1]+0 == 2 && a[2]+0 >= 38) exit 0; exit 1 }'; then
    die "glibc $GLIBC_VER is too old; the cross toolchain needs >= 2.38.
     Supported: Debian 13, Ubuntu 24.04 or newer.
     Install one with:  wsl --install -d Debian"
fi
ok "glibc $GLIBC_VER >= 2.38"

if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
    HAS_SYSTEMD=1; ok "systemd is PID 1"
else
    HAS_SYSTEMD=0
    warn "systemd is not PID 1; the runner will not auto-start at boot"
    warn "enable it by adding [boot] systemd=true to /etc/wsl.conf, then: wsl --shutdown"
fi

# -------------------------------------------------------------------- deps ---
step "Installing build prerequisites"
if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq
    # `$SUDO VAR=value cmd` breaks when SUDO is empty: bash would treat
    # "VAR=value" as the command name. `env` makes it unambiguous.
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        python3 cmake ninja-build git xz-utils curl ca-certificates
    ok "apt packages installed"
else
    warn "apt-get not found; install manually: python3 cmake ninja git xz-utils curl"
fi
python3 -c 'import sys; print("  python3:", sys.version.split()[0])'
command -v cmake  >/dev/null && echo "  cmake  : $(cmake --version | head -1)"
command -v ninja  >/dev/null && echo "  ninja  : $(ninja --version)"
command -v git    >/dev/null && echo "  git    : $(git --version)"

# ------------------------------------------------------------------ bundle ---
step "Locating the IA-64 toolchain bundle"
if [[ -z "$BUNDLE_FILE" ]]; then
    for cand in \
        /mnt/*/kasuga-ia64-toolchain-*.tar.xz \
        /mnt/*/*/kasuga-ia64-toolchain-*.tar.xz \
        "$HOME"/kasuga-ia64-toolchain-*.tar.xz \
        /media/*/*/kasuga-ia64-toolchain-*.tar.xz
    do
        # shellcheck disable=SC2086
        if [[ -f $cand ]]; then BUNDLE_FILE="$cand"; break; fi
    done
fi
[[ -n "$BUNDLE_FILE" && -f "$BUNDLE_FILE" ]] || die "bundle not found.
     Copy kasuga-ia64-toolchain-slim-*.tar.xz to D:\\ or the USB stick and
     pass its path:  -b /mnt/d/kasuga-ia64-toolchain-slim-*.tar.xz"
echo "  bundle : $BUNDLE_FILE ($(du -h "$BUNDLE_FILE" | cut -f1))"
ok "checksum file present: $([[ -f "${BUNDLE_FILE%.tar.xz}.tar.sha256" || -f "${BUNDLE_FILE}.sha256" ]] && echo yes || echo no)"
for f in "${BUNDLE_FILE%.tar.xz}.tar.sha256" "${BUNDLE_FILE}.sha256"; do
    if [[ -f "$f" ]]; then
        ( cd "$(dirname "$BUNDLE_FILE")" && sha256sum -c "$(basename "$f")" ) || die "checksum mismatch"
        ok "sha256 verified"; break
    fi
done

step "Unpacking to $BUNDLE_DEST"
$SUDO mkdir -p "$BUNDLE_DEST"
$SUDO tar -xJf "$BUNDLE_FILE" -C "$BUNDLE_DEST"
BUNDLE_DIR="$BUNDLE_DEST/kasuga-ia64-toolchain"
[[ -f "$BUNDLE_DIR/env.sh" ]] || die "unexpected bundle layout: $BUNDLE_DIR/env.sh missing"
ok "unpacked: $BUNDLE_DIR"

step "Verifying the cross compiler"
# shellcheck disable=SC1090
. "$BUNDLE_DIR/env.sh" >/dev/null
"${IA64_TOOLCHAIN_PREFIX}gcc" --version | head -1
printf 'int main(void){return 0;}' > /tmp/_ia64_probe.c
"${IA64_TOOLCHAIN_PREFIX}gcc" /tmp/_ia64_probe.c -o /tmp/_ia64_probe
file /tmp/_ia64_probe | grep -qi 'IA-64' || die "compiler produced a non-IA-64 object"
ok "compiler works and emits IA-64 ELF"
rm -f /tmp/_ia64_probe /tmp/_ia64_probe.c
{
    echo "# Added by setup-wsl-runner.sh"
    echo ". $BUNDLE_DIR/env.sh >/dev/null 2>&1"
} >> "$HOME/.bashrc"
ok "env.sh sourced from ~/.bashrc for future shells"

# ------------------------------------------------------------------ runner ---
step "Installing the GitHub Actions runner"
if [[ -z "$TOKEN" ]]; then
    warn "no token supplied (-t/--token). Environment is ready; finish with:"
    echo "    cd $RUNNER_DIR"
    echo "    ./config.sh --url $REPO_URL --token <TOKEN> --name $RUNNER_NAME --labels $LABELS --unattended"
    echo "    ./run.sh            # foreground, or: sudo ./svc.sh install && sudo ./svc.sh start"
    exit 0
fi

mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"

if [[ ! -f config.sh ]]; then
    VER="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
           | grep -oE '"tag_name": *"v[0-9.]+"' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
    [[ -n "$VER" ]] || die "could not determine the latest runner version"
    ZIP="actions-runner-linux-x64-${VER}.tar.gz"
    echo "  downloading $ZIP"
    curl -fsSL -o "$ZIP" "https://github.com/actions/runner/releases/download/v${VER}/${ZIP}"
    curl -fsSL -o "${ZIP}.sha256" "https://github.com/actions/runner/releases/download/v${VER}/${ZIP}.sha256" || true
    if [[ -f "${ZIP}.sha256" ]]; then
        # The published file is "<hash>  <name>"; normalise then verify.
        awk '{print $1"  '"$ZIP"'"}' "${ZIP}.sha256" | sha256sum -c - || die "runner archive checksum mismatch"
        ok "runner archive verified"
    fi
    tar -xzf "$ZIP"
    rm -f "$ZIP" "${ZIP}.sha256"
    ok "runner unpacked into $RUNNER_DIR"
else
    ok "runner already present in $RUNNER_DIR"
fi

if [[ -f .runner ]]; then
    ok "runner already configured; skipping config.sh"
else
    echo "  configuring runner '$RUNNER_NAME' with labels '$LABELS'"
    ./config.sh --url "$REPO_URL" --token "$TOKEN" \
        --name "$RUNNER_NAME" --labels "$LABELS" --work "$RUNNER_DIR/_work" --unattended --replace
    ok "runner configured"
fi

if [[ "$INSTALL_SERVICE" == "1" ]]; then
    if [[ "$HAS_SYSTEMD" == "1" ]]; then
        $SUDO ./svc.sh install "$(id -un)"
        $SUDO ./svc.sh start
        $SUDO ./svc.sh status || true
        ok "systemd service installed"
    else
        warn "skipping service install (no systemd). Start it manually with:"
        echo "    cd $RUNNER_DIR && ./run.sh"
        echo "  or enable systemd: add '[boot]' + 'systemd=true' to /etc/wsl.conf,"
        echo "  run 'wsl --shutdown' in Windows, reopen, then re-run with --no-service=0"
    fi
fi

step "Done"
echo "  runner : $RUNNER_NAME"
echo "  labels : self-hosted, Linux, X64, $LABELS"
echo "  repo   : $REPO_URL"
echo "  bundle : $BUNDLE_DIR"
echo
echo "Verify in GitHub: Settings -> Actions -> Runners (should show Idle)."
echo "Then trigger the experimental workflow with include_self_hosted = true."
