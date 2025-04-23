#!/usr/bin/env bash

# Box - A minimal full-terminal AUR helper
# Simplified version without previews and descriptions

# Configuration
AUR_REPO_URL="https://aur.archlinux.org"
TMP_DIR="/tmp/box_aur"
USE_FZF=true
SHOW_PACMAN_ONLY=false
FZF_OPTS="--height 100% --border --ansi --layout=reverse"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Setup
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Package listing functions
search_aur() {
    local query=$1
    curl -s "$AUR_REPO_URL/rpc/?v=5&type=search&arg=$query" | \
    jq -r '.results[] | "\(.Name)|\(.Version)"' 2>/dev/null | \
    while IFS='|' read -r name version; do
        printf "${MAGENTA}[aur] ${CYAN}%-30s ${YELLOW}%s${NC}\n" "$name" "$version"
    done
}

search_pacman() {
    local query=$1
    pacman -Ss "$query" | awk '
        /^core/ {printf "\033[1;31m[pacman] %-30s \033[1;33m", $2, $3}
        /^extra/ {printf "\033[1;33m[pacman] %-30s \033[1;33m", $2, $3}
        /^community/ {printf "\033[1;36m[pacman] %-30s \033[1;33m", $2, $3}
        /^multilib/ {printf "\033[1;35m[pacman] %-30s \033[1;33m", $2, $3}
        /\[installed\]/ {printf "\033[0;32m%s\033[0m\n", $0; next}
        {print $0}
    ' | grep -E '^\[pacman\]'
}

# Package management
install_package() {
    local pkg=$1 is_aur=$2
    if [[ "$is_aur" == true ]]; then
        echo -e "${MAGENTA}Installing ${CYAN}$pkg ${MAGENTA}from AUR...${NC}"
        if git clone "$AUR_REPO_URL/$pkg.git" "$TMP_DIR/$pkg" && cd "$TMP_DIR/$pkg"; then
            makepkg -si --noconfirm && echo -e "${GREEN}Installed ${CYAN}$pkg${NC}" || echo -e "${RED}Failed ${CYAN}$pkg${NC}"
            cd - >/dev/null
        else
            echo -e "${RED}Failed to clone ${CYAN}$pkg${NC}"
        fi
    else
        echo -e "${BLUE}Installing ${CYAN}$pkg...${NC}"
        sudo pacman -S --noconfirm "$pkg" && echo -e "${GREEN}Installed ${CYAN}$pkg${NC}" || echo -e "${RED}Failed ${CYAN}$pkg${NC}"
    fi
}

remove_package() {
    local pkg=$1 recursive=$2
    if pacman -Q "$pkg" &>/dev/null; then
        if [[ "$recursive" == true ]]; then
            sudo pacman -Rns --noconfirm "$pkg" && echo -e "${GREEN}Removed ${CYAN}$pkg${NC}" || echo -e "${RED}Failed ${CYAN}$pkg${NC}"
        else
            sudo pacman -R --noconfirm "$pkg" && echo -e "${GREEN}Removed ${CYAN}$pkg${NC}" || echo -e "${RED}Failed ${CYAN}$pkg${NC}"
        fi
    else
        echo -e "${RED}Not installed ${CYAN}$pkg${NC}"
    fi
}

# Interactive functions
interactive_search() {
    local query=$1
    local results=$(echo -e "$(search_pacman "$query")\n$(search_aur "$query")" | grep -v '^$')
    
    if [[ -z "$results" ]]; then
        echo -e "${RED}No results for ${CYAN}$query${NC}"
        return
    fi

    if [[ "$USE_FZF" == true ]] && command -v fzf >/dev/null; then
        local selected=$(echo -e "$results" | fzf $FZF_OPTS | awk '{print $2}')
        [[ -n "$selected" ]] && install_package "$selected" "$(echo "$results" | grep -q "^\[aur\] $selected " && echo true || echo false)"
    else
        echo -e "${BLUE}Results:${NC}\n$results" | nl
        read -p "Enter number to install (0 to cancel): " choice
        [[ "$choice" -gt 0 ]] && {
            local selected=$(echo -e "$results" | sed -n "${choice}p" | awk '{print $2}')
            install_package "$selected" "$(echo "$results" | sed -n "${choice}p" | grep -q "^\[aur\]" && echo true || echo false)"
        }
    fi
}

interactive_remove() {
    local recursive=$1
    local installed=$(pacman -Qe | while read pkg ver; do
        printf "${BLUE}[%s] ${CYAN}%-30s ${YELLOW}%s${NC}\n" \
               "$(pacman -Qm | grep -q "^$pkg " && echo "aur" || echo "pacman")" \
               "$pkg" "$ver"
    done)

    if [[ "$USE_FZF" == true ]] && command -v fzf >/dev/null; then
        local selected=$(echo -e "$installed" | fzf $FZF_OPTS | awk '{print $2}')
        [[ -n "$selected" ]] && remove_package "$selected" "$recursive"
    else
        echo -e "${BLUE}Installed:${NC}\n$installed" | nl
        read -p "Enter number to remove (0 to cancel): " choice
        [[ "$choice" -gt 0 ]] && remove_package "$(echo -e "$installed" | sed -n "${choice}p" | awk '{print $2}')" "$recursive"
    fi
}

update_packages() {
    echo -e "${YELLOW}Updating pacman packages...${NC}"
    sudo pacman -Syu --noconfirm || echo -e "${RED}Pacman update failed${NC}"
    
    [[ "$SHOW_PACMAN_ONLY" != true ]] && {
        echo -e "${YELLOW}Checking AUR packages...${NC}"
        pacman -Qm | while read pkg ver; do
            aur_ver=$(curl -s "$AUR_REPO_URL/rpc/?v=5&type=info&arg[]=$pkg" | jq -r '.results[0].Version')
            [[ "$ver" != "$aur_ver" ]] && {
                echo -e "${BLUE}Updating ${CYAN}$pkg ${YELLOW}$ver -> $aur_ver${NC}"
                install_package "$pkg" true
            }
        done
    }
}

show_help() {
    echo -e "${GREEN}Box Commands:${NC}
  search <query>    Search packages
  add <pkg>         Install package
  remove <pkg>      Remove package
  update            Update all packages
  help              Show this help

${YELLOW}Options:${NC}
  --pacman-only     Search only official repos
  --no-fzf         Disable fzf
  --recursive       Remove with dependencies
  -y, --noconfirm   Skip confirmations"
}

# Main function
main() {
    local noconfirm=false recursive=false
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pacman-only) SHOW_PACMAN_ONLY=true ;;
            --no-fzf) USE_FZF=false ;;
            -y|--noconfirm) noconfirm=true ;;
            --recursive) recursive=true ;;
            *) break ;;
        esac
        shift
    done

    case "$1" in
        search) interactive_search "$2" ;;
        add) install_package "$2" "$(pacman -Qm | grep -q "^$2 " && echo true || echo false)" ;;
        remove) [[ -z "$2" ]] && interactive_remove "$recursive" || remove_package "$2" "$recursive" ;;
        update) update_packages ;;
        help|--help|-h) show_help ;;
        *) [[ -n "$1" ]] && interactive_search "$1" || show_help ;;
    esac
}

main "$@"
