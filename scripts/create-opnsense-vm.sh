#!/bin/bash
# =============================================================================
# create-opnsense-vm.sh
# Création automatique de la VM OPNsense sur Proxmox via CLI
#
# Usage :
#   bash create-opnsense-vm.sh
#   bash create-opnsense-vm.sh --dry-run   # Affiche les commandes sans les exécuter
#
# Prérequis :
#   - Script à exécuter directement sur le host Proxmox
#   - ISO OPNsense déjà uploadée dans local:iso
#   - Bridges vmbr0, vmbr1, vmbr2 déjà créés
# =============================================================================

set -euo pipefail

# ─── Couleurs ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Variables — adapter à votre environnement ───────────────────────────────
VM_ID="100"
VM_NAME="opnsense-fw"
ISO_NAME="OPNsense-26.1.2-dvd-amd64.iso"   # Nom exact de l'ISO dans local:iso
STORAGE="local-lvm"
DISK_SIZE="20"                               # Go
RAM="2048"                                   # Mo
CORES="2"
CPU_TYPE="host"
BRIDGE_WAN="vmbr0"
BRIDGE_LAN="vmbr1"
BRIDGE_DMZ="vmbr2"

# ─── Mode dry-run ────────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${YELLOW}[DRY-RUN] Aucune commande ne sera exécutée${NC}"
fi

run() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}[CMD]${NC} $*"
    else
        "$@"
    fi
}

# ─── Fonctions ───────────────────────────────────────────────────────────────
log_info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
log_section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; \
                echo -e "${BLUE}  $1${NC}"; \
                echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ─── Vérifications préalables ────────────────────────────────────────────────
log_section "Vérifications préalables"

# Vérifier qu'on est bien sur le host Proxmox
if ! command -v qm &> /dev/null; then
    log_error "Commande 'qm' introuvable. Ce script doit être exécuté sur le host Proxmox."
fi

# Vérifier que l'ISO existe
if ! pvesm list local 2>/dev/null | grep -q "$ISO_NAME"; then
    log_error "ISO '$ISO_NAME' introuvable dans local:iso. Uploadez l'ISO avant de lancer ce script."
fi

# Vérifier que les bridges existent
for bridge in "$BRIDGE_WAN" "$BRIDGE_LAN" "$BRIDGE_DMZ"; do
    if ! ip link show "$bridge" &>/dev/null; then
        log_error "Bridge '$bridge' introuvable. Créez les bridges réseau avant de lancer ce script."
    fi
done

# Vérifier que la VM ID n'est pas déjà utilisée
if qm status "$VM_ID" &>/dev/null; then
    log_error "VM ID $VM_ID déjà utilisée. Modifiez la variable VM_ID dans le script."
fi

log_info "Vérifications OK"

# ─── Création de la VM ───────────────────────────────────────────────────────
log_section "Création de la VM $VM_NAME (ID: $VM_ID)"

log_info "Création de la VM de base..."
run qm create "$VM_ID" \
    --name "$VM_NAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu "$CPU_TYPE" \
    --bios seabios \
    --machine q35 \
    --ostype other \
    --scsihw virtio-scsi-pci \
    --boot order=ide2 \
    --onboot 1

# ─── Disque ──────────────────────────────────────────────────────────────────
log_info "Création du disque ($DISK_SIZE Go sur $STORAGE)..."
run qm set "$VM_ID" \
    --scsi0 "$STORAGE:$DISK_SIZE,cache=writeback"

# ─── ISO ─────────────────────────────────────────────────────────────────────
log_info "Montage de l'ISO OPNsense..."
run qm set "$VM_ID" \
    --ide2 "local:iso/$ISO_NAME,media=cdrom"

# ─── Interfaces réseau ───────────────────────────────────────────────────────
log_info "Configuration des interfaces réseau..."

# net0 → WAN
run qm set "$VM_ID" \
    --net0 "virtio,bridge=$BRIDGE_WAN,firewall=0"

# net1 → LAN
run qm set "$VM_ID" \
    --net1 "virtio,bridge=$BRIDGE_LAN,firewall=0"

# net2 → DMZ
run qm set "$VM_ID" \
    --net2 "virtio,bridge=$BRIDGE_DMZ,firewall=0"

# ─── Ordre de boot ───────────────────────────────────────────────────────────
log_info "Configuration de l'ordre de boot..."
run qm set "$VM_ID" \
    --boot order="ide2;scsi0"

# ─── Résumé ──────────────────────────────────────────────────────────────────
log_section "VM créée avec succès"

echo -e "  VM ID       : ${GREEN}$VM_ID${NC}"
echo -e "  Nom         : ${GREEN}$VM_NAME${NC}"
echo -e "  CPU         : ${GREEN}$CORES cœurs — type $CPU_TYPE${NC}"
echo -e "  RAM         : ${GREEN}$RAM Mo${NC}"
echo -e "  Disque      : ${GREEN}$DISK_SIZE Go — $STORAGE${NC}"
echo -e "  BIOS        : ${GREEN}SeaBIOS${NC}"
echo -e "  net0 (WAN)  : ${GREEN}$BRIDGE_WAN${NC}"
echo -e "  net1 (LAN)  : ${GREEN}$BRIDGE_LAN${NC}"
echo -e "  net2 (DMZ)  : ${GREEN}$BRIDGE_DMZ${NC}"

echo ""
log_info "Prochaine étape : démarrer la VM et procéder à l'installation OPNsense"
echo -e "  ${BLUE}qm start $VM_ID${NC}"
echo -e "  Puis ouvrir la console : ${BLUE}https://IP_PROXMOX:8006${NC}"
echo ""
log_warn "Ne pas oublier d'éjecter l'ISO après l'installation :"
echo -e "  ${BLUE}qm set $VM_ID --ide2 none,media=cdrom${NC}"
