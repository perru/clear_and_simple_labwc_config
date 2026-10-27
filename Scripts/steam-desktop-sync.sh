#!/usr/bin/env bash
# steam-desktop-sync : crée un .desktop + une icône pour chaque jeu Steam installé
# (StartupWMClass=steam_app_<ID>, pour que Waybar/wlr-taskbar trouve la bonne icône)
#
# Dépendance : imagemagick (commande "magick" ou "convert")
set -euo pipefail

STEAM_CMD="${STEAM_CMD:-steam-native}"
APPS_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$APPS_DIR" "$ICON_DIR"

# --- Localisation de Steam -------------------------------------------------
if [ -n "${STEAM_DIR:-}" ]; then
  STEAM="$STEAM_DIR"
else
  for c in "$HOME/.local/share/Steam" \
           "$HOME/.steam/steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -f "$c/steamapps/libraryfolders.vdf" ] && { STEAM="$c"; break; }
  done
fi
[ -n "${STEAM:-}" ] || { echo "Steam introuvable, définis STEAM_DIR" >&2; exit 1; }
CACHE="$STEAM/appcache/librarycache"

# --- ImageMagick -----------------------------------------------------------
if command -v magick >/dev/null; then IM=(magick)
elif command -v convert >/dev/null; then IM=(convert)
else echo "Installe imagemagick (magick/convert introuvable)" >&2; exit 1; fi

# --- Recherche de l'icône d'un jeu dans le cache Steam ---------------------
# Retourne : "icon|chemin" (vraie icône) ou "header|chemin" (repli) ou rien
find_source() {
  local id=$1 f
  # Ancien format : <id>_icon.jpg
  f="$CACHE/${id}_icon.jpg"
  [ -f "$f" ] && { echo "icon|$f"; return; }
  # Nouveau format : dossier <id>/ avec un fichier nommé par hash (40 hex)
  if [ -d "$CACHE/$id" ]; then
    f=$(find "$CACHE/$id" -maxdepth 2 -type f -regextype posix-extended \
          -regex '.*/[0-9a-f]{40}\.(jpg|png)' 2>/dev/null | head -n1 || true)
    [ -n "$f" ] && { echo "icon|$f"; return; }
    # Repli : bannière header, recadrée en carré
    f="$CACHE/$id/header.jpg"
    [ -f "$f" ] && { echo "header|$f"; return; }
  fi
  [ -f "$CACHE/${id}_header.jpg" ] && echo "header|$CACHE/${id}_header.jpg" || true
}

make_icon() {
  local id=$1 dst="$ICON_DIR/steam_icon_$1.png" kind src res
  [ -f "$dst" ] && return 0
  # Icône déjà créée par Steam (raccourci manuel) dans une autre taille ?
  compgen -G "$HOME/.local/share/icons/hicolor/*/apps/steam_icon_$id.png" >/dev/null && return 0

  res=$(find_source "$id")
  [ -n "$res" ] || return 1
  kind=${res%%|*}; src=${res#*|}

  if [ "$kind" = "icon" ]; then
    "${IM[@]}" "$src" -resize 256x256 "png:$dst"
  else
    "${IM[@]}" "$src" -resize 256x256^ -gravity center -extent 256x256 "png:$dst"
  fi
}

# --- Toutes les bibliothèques Steam ----------------------------------------
mapfile -t libs < <(grep -oP '"path"\s+"\K[^"]+' "$STEAM/steamapps/libraryfolders.vdf")

created=0; noicon=0
for lib in "${libs[@]}"; do
  for acf in "$lib"/steamapps/appmanifest_*.acf; do
    [ -e "$acf" ] || continue
    id=$(grep -m1 -oP '"appid"\s+"\K[0-9]+' "$acf")
    name=$(grep -m1 -oP '"name"\s+"\K[^"]+' "$acf")

    # On ignore les outils (Proton, runtimes, redistribuables)
    case "$name" in
      Proton*|"Steam Linux Runtime"*|"Steamworks Common"*) continue ;;
    esac

    if make_icon "$id"; then icon="steam_icon_$id"; else icon="steam"; noicon=$((noicon+1)); fi

    cat > "$APPS_DIR/steam_app_$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Comment=Lancer $name via Steam
Exec=$STEAM_CMD steam://rungameid/$id
Icon=$icon
StartupWMClass=steam_app_$id
Categories=Game;
EOF
    created=$((created+1))
  done
done

# Rafraîchit le cache d'icônes si possible (sans erreur si indisponible)
gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

echo "$created jeux traités, $noicon sans icône trouvée (icône Steam générique utilisée)."
