#!/bin/bash

set -ouex pipefail

# Statische Dateien (Units, Preset, dconf, sysctl, Skripte, Flatpak-Preinstall)
# aus system_files/ des Git-Repos nach / kopieren — Modes (inkl. +x) kommen aus Git.
cp -avf "/ctx/system_files"/. /

### Pakete

dnf5 install -y tmux

### RustDesk nativ (unattended Fernzugriff fuer Kunden + Maintenance)
# Warum im Image statt Flatpak/AppImage: Nur mit laufendem RustDesk-*Dienst* nimmt der
# Client den ScreenCast-Portal-Pfad mit persist_mode=2 + restore_token -> die
# Bildschirmfreigabe ueberlebt Reboots ohne Bestaetigungs-Dialog. Das Flatpak kann das
# prinzipbedingt nicht (RemoteDesktop-Portal-Pfad ohne persist, Upstream-TODO in
# libs/scrap/src/wayland/pipewire.rs). Das RPM liefert Binary + Unit + Desktop-Eintrag
# als EIN Artefakt; Updates/Rollback laufen ueber bootc mit (Version-Bump = Commit hier).
# Identitaet/permanentes Passwort (RustDesk.toml unter /root bzw. $HOME) und der
# Portal-Grant bleiben bewusst machine-local - keine Secrets im Image.
# Version gepinnt + Checksum-verifiziert: GitHub-Release-RPMs sind nicht repo-signiert,
# ein kompromittiertes Upstream-Release soll NICHT automatisch einfliessen.
# Details: Vault-Pattern 2026-07-13-rustdesk-unattended-gnome-wayland-service-mode
RUSTDESK_VERSION=1.4.9
RUSTDESK_SHA256=eb1b053ac5b2f774f2271f7fbbfd2ea475899f7a55135c5e172bc54b9388f108
curl -fsSL -o /tmp/rustdesk.rpm \
    "https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-0.x86_64.rpm"
echo "${RUSTDESK_SHA256}  /tmp/rustdesk.rpm" | sha256sum -c -
dnf5 install -y /tmp/rustdesk.rpm
rm -f /tmp/rustdesk.rpm
# Das RustDesk-RPM legt die Unit NUR als Vorlage nach /usr/share/rustdesk/files/ ab
# (keine aktive systemd-Unit an einem Suchpfad) -> explizit nach /usr/lib kopieren,
# sonst "Unit rustdesk.service does not exist" auf frischer Installation.
# Verifiziert MONDZENTRUM 2026-07-13.
install -Dm644 /usr/share/rustdesk/files/rustdesk.service /usr/lib/systemd/system/rustdesk.service

### Dienste enablen — Preset + enable als PAAR
# Die Preset-Regeln liegen in system_files/usr/lib/systemd/system-preset/
# 20-lightrechner.preset: ohne Preset-Regel kassiert die Preset-Neuberechnung
# beim Boot den enable-Symlink wieder ein (Learning 2026-07-13). docker.service
# ist auf bluefin-dx per Vendor-Preset NICHT gedeckt (nur docker.socket) und
# waere sonst nach Reboot aus -> Compose-Stack tot, Host ggf. unerreichbar
# (Learning 2026-05-21-bluefin-docker-service-disabled-default-server-lockout).
systemctl enable docker.service tailscaled.service rustdesk.service podman.socket

### RustDesk-Determinismus: System-Remote-Login (3389) hart deaktivieren
# gnome-remote-desktop System-Mode (Port 3389, Remote-Login/Handover) haelt permanent
# eine parallele gdm-greeter-Session bereit. RustDesks --service spawnt --server/--cm
# fuer JEDE grafische Session; landet der Connection-Manager (ipc_cm) in der
# gdm-greeter-Session (kein persistenter Portal-Grant, fluechtiges HOME), fragt RustDesk
# bei JEDEM Connect neu nach der Bildschirmfreigabe -> unattended-Zugriff kaputt.
# Das Symptom ist nicht-deterministisch (Session-Roulette) — hat die Diagnose
# 2026-07-13 auf MONDZENTRUM lange verschleiert.
# Fix: System-GRD maskieren -> nur die Operator-Auto-Login-Session existiert ->
# RustDesk bedient deterministisch die Session mit dem Grant. mask statt disable,
# weil das Atomic-Preset ein disable beim Boot re-aktiviert (Learning 2026-07-12).
# Trade-off: kein RDP-Desktop-Zugang (Remmina) mehr ueber 3389; RustDesk ist der
# GUI-Weg, Tailscale SSH der Terminal-Notfall.
systemctl mask gnome-remote-desktop.service

### 24/7-Leitwarte: Sleep-Targets systemweit maskieren
# Der dconf-Greeter-Fix (system_files: etc/dconf/db/gdm.d/10-no-suspend) deckt nur
# den GDM-Anmeldebildschirm ab; ein logind IdleAction-/Lid-/manueller Suspend kaeme
# trotzdem durch. Leitrechner sollen NIE schlafen -> Targets hart maskieren.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

### dconf-Datenbanken kompilieren (gdm.d + local.d aus system_files)
dconf update
