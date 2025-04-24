#!/usr/bin/env bash
AUR_REPO_URL="https://aur.archlinux.org"
TMP_DIR="/tmp/box_aur"
USE_FZF=true
FZF_OPTS="--height 100% --border --ansi --layout=reverse"
PACMAN_COLOR='\033[1;33m'
AUR_COLOR='\033[1;35m'
INSTALLED_COLOR='\033[1;32m'
VERSION_COLOR='\033[0;36m'
ERROR_COLOR='\033[1;31m'
NC='\033[0m'

mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

is_installed() {
    pacman -Q "$1" &>/dev/null
}

is_aur_package() {
    curl -s "$AUR_REPO_URL/rpc/?v=5&type=info&arg[]=$1" | jq -e '.results[0]' >/dev/null
}

search_pacman() {
    pacman -Ss "$1" | awk -v pc="$PACMAN_COLOR" -v ic="$INSTALLED_COLOR" -v nc="$NC" '
        /^core/ || /^extra/ || /^community/ || /^multilib/ {
            pkg=$2; ver=$3; $1=$2=$3=""; desc=$0;
            if ($0 ~ /\[installed\]/) {
                printf "%s[pacman] %-30s %s%s%s\n", pc, pkg, ic, ver, nc
            } else {
                printf "%s[pacman] %-30s %s%s%s\n", pc, pkg, VERSION_COLOR, ver, nc
            }
        }'
}

search_aur() {
    curl -s "$AUR_REPO_URL/rpc/?v=5&type=search&arg=$1" | \
    jq -r '.results[] | "\(.Name)|\(.Version)"' | \
    while IFS='|' read -r name version; do
        if is_installed "$name"; then
            printf "%s[aur] %-30s %s%s%s\n" "$AUR_COLOR" "$name" "$INSTALLED_COLOR" "$version" "$NC"
        else
            printf "%s[aur] %-30s %s%s%s\n" "$AUR_COLOR" "$name" "$VERSION_COLOR" "$version" "$NC"
        fi
    done
}

add_aur_package() {
    local pkg=$1
    echo -e "${AUR_COLOR}Adding AUR package: ${VERSION_COLOR}$pkg${NC}"
    
    if ! git clone "$AUR_REPO_URL/$pkg.git" "$TMP_DIR/$pkg" 2>/dev/null; then
        echo -e "${ERROR_COLOR}Failed to clone $pkg repository${NC}"
        return 1
    fi

    cd "$TMP_DIR/$pkg" || return 1
    if ! makepkg -si --noconfirm; then
        echo -e "${ERROR_COLOR}Failed to build/add $pkg${NC}"
        cd - >/dev/null
        return 1
    fi
    cd - >/dev/null
    
    echo -e "${INSTALLED_COLOR}Successfully added $pkg${NC}"
}

add_pacman_package() {
    local pkg=$1
    echo -e "${PACMAN_COLOR}Adding package: ${VERSION_COLOR}$pkg${NC}"
    sudo pacman -S --noconfirm "$pkg" && \
        echo -e "${INSTALLED_COLOR}Successfully added $pkg${NC}" || \
        echo -e "${ERROR_COLOR}Failed to add $pkg${NC}"
}

interactive_search() {
    local query=$1
    local results=$(echo -e "$(search_pacman "$query")\n$(search_aur "$query")")
    
    if [[ -z "$results" ]]; then
        echo -e "${ERROR_COLOR}No packages found${NC}"
        return 1
    fi

    if [[ "$USE_FZF" == true ]] && command -v fzf >/dev/null; then
        local selected=$(echo -e "$results" | fzf $FZF_OPTS | awk '{print $2}')
        [[ -n "$selected" ]] && {
            if echo "$results" | grep -q "^\[aur\] $selected "; then
                add_aur_package "$selected"
            else
                add_pacman_package "$selected"
            fi
        }
    else
        echo -e "$results" | nl
        read -p "Enter number to add (0 to cancel): " choice
        [[ "$choice" -gt 0 ]] && {
            local selected=$(echo -e "$results" | sed -n "${choice}p" | awk '{print $2}')
            if echo "$results" | sed -n "${choice}p" | grep -q "^\[aur\]"; then
                add_aur_package "$selected"
            else
                add_pacman_package "$selected"
            fi
        }
    fi
}

interactive_remove() {
    local installed=$(pacman -Qe | while read pkg ver; do
        if pacman -Qm | grep -q "^$pkg "; then
            printf "${AUR_COLOR}[aur] %-30s ${VERSION_COLOR}%s${NC}\n" "$pkg" "$ver"
        else
            printf "${PACMAN_COLOR}[pacman] %-30s ${VERSION_COLOR}%s${NC}\n" "$pkg" "$ver"
        fi
    done)

    if [[ "$USE_FZF" == true ]] && command -v fzf >/dev/null; then
        local selected=$(echo -e "$installed" | fzf $FZF_OPTS | awk '{print $2}')
        [[ -n "$selected" ]] && {
            echo -e "${ERROR_COLOR}Removing $selected...${NC}"
            sudo pacman -R --noconfirm "$selected" && \
                echo -e "${INSTALLED_COLOR}Removed $selected${NC}" || \
                echo -e "${ERROR_COLOR}Failed to remove $selected${NC}"
        }
    else
        echo -e "$installed" | nl
        read -p "Enter number to remove (0 to cancel): " choice
        [[ "$choice" -gt 0 ]] && {
            local selected=$(echo -e "$installed" | sed -n "${choice}p" | awk '{print $2}')
            echo -e "${ERROR_COLOR}Removing $selected...${NC}"
            sudo pacman -R --noconfirm "$selected" && \
                echo -e "${INSTALLED_COLOR}Removed $selected${NC}" || \
                echo -e "${ERROR_COLOR}Failed to remove $selected${NC}"
        }
    fi
}

update_packages() {
    echo -e "${PACMAN_COLOR}Updating pacman packages...${NC}"
    sudo pacman -Syu --noconfirm
    
    echo -e "${AUR_COLOR}Checking AUR updates...${NC}"
    pacman -Qm | while read pkg ver; do
        aur_ver=$(curl -s "$AUR_REPO_URL/rpc/?v=5&type=info&arg[]=$pkg" | jq -r '.results[0].Version')
        if [[ "$ver" != "$aur_ver" ]]; then
            echo -e "${VERSION_COLOR}Updating $pkg ($ver -> $aur_ver)${NC}"
            add_aur_package "$pkg"
        fi
    done
}

show_help() {
    echo -e "
${PACMAN_COLOR}Box - Minimal AUR Helper${NC}

${INSTALLED_COLOR}Usage:${NC}
  box search <query>   Search packages
  box add <pkg>        Add/install package
  box remove <pkg>     Remove package
  box update           Update all packages
  box help             Show this help

${VERSION_COLOR}Options:${NC}
  No options needed - just simple commands
"
}

main() {
    case "$1" in
        search) interactive_search "$2" ;;
        add)
            if is_aur_package "$2"; then
                add_aur_package "$2"
            else
                add_pacman_package "$2"
            fi
            ;;
        remove) interactive_remove ;;
        update) update_packages ;;
        help|--help|-h) show_help ;;
        *)
            if [[ -n "$1" ]]; then
                interactive_search "$1"
            else
                show_help
            fi
            ;;
    esac
}

main "$@"
