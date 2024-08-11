#!/usr/bin/env bash
#===============================================================================
#          FILE: samba.sh
#
#         USAGE: ./samba.sh
#
#   DESCRIPTION: Entrypoint for samba docker container
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: David Personette (dperson@gmail.com)
#    Modificado: Yasser Jara (yasserjara@gmail.com)
#         Fecha: 10/08/2024 10:52
#  ORGANIZATION:
#       CREATED: 09/28/2014 12:11
#      REVISION: 1.1 - Updated for performance and readability
#===============================================================================

set -o nounset  # Treat unset variables as an error

# Utility function to update a configuration option in a specific section
update_config_option() {
    local section="$1"
    local option="$2"
    local file="/etc/samba/smb.conf"
    
    if sed -n "/^\[$section\]/,/^\[/p" "$file" | grep -qE "^;*\s*${option%%=*}"; then
        sed -i "/^\[$section\]/,/^\[/s|^;*\s*\(${option%%=*}\).*|   ${option}|" "$file"
    else
        sed -i "/^\[$section\]/a \   ${option}" "$file"
    fi
}

# Function to configure character mapping for file/directory names
charmap() {
    local chars="$1"
    local file="/etc/samba/smb.conf"
    
    grep -q "catia" "$file" || {
        sed -i '/TCP_NODELAY/a \
        vfs objects = catia\
        catia:mappings =\
        ' "$file"
    }
    
    sed -i "/catia:mappings/s| =.*| = ${chars}|" "$file"
}

# Function to add a generic config option in a specific section
generic() {
    local section="$1"
    local option="$2"
    update_config_option "$section" "$option"
}

# Function to add a global config option
global() {
    local option="$1"
    update_config_option "global" "$option"
}

# Function to add an include statement in smb.conf
include() {
    local includefile="$1"
    local file="/etc/samba/smb.conf"
    
    sed -i "\\|include = $includefile|d" "$file"
    echo "include = $includefile" >> "$file"
}

# Function to import a smbpasswd file
import() {
    local file="$1"
    
    while IFS=: read -r name id; do
        grep -q "^$name:" /etc/passwd || adduser -D -H -u "$id" "$name"
    done < <(cut -d: -f1,2 "$file")
    
    pdbedit -i smbpasswd:"$file"
}

# Function to fix ownership and permissions of share paths
perms() {
    local file="/etc/samba/smb.conf"
    
    awk -F ' = ' '/   path = / {print $2}' "$file" | while read -r i; do
        chown -Rh smbuser. "$i"
        find "$i" -type d ! -perm 775 -exec chmod 775 {} \;
        find "$i" -type f ! -perm 0664 -exec chmod 0664 {} \;
    done
}

# Function to disable recycle bin
recycle() {
    local file="/etc/samba/smb.conf"
    
    sed -i '/recycle:/d; /vfs objects/s/ recycle / /' "$file"
}

# Function to add a share configuration
share() {
    local share="$1"
    local path="$2"
    local browsable="${3:-yes}"
    local ro="${4:-yes}"
    local guest="${5:-yes}"
    local users="${6:-""}"
    local admins="${7:-""}"
    local writelist="${8:-""}"
    local comment="${9:-""}"
    local file="/etc/samba/smb.conf"
    
    sed -i "/\\[$share\\]/,/^\$/d" "$file"
    {
        echo "[$share]"
        echo "   path = $path"
        echo "   browsable = $browsable"
        echo "   read only = $ro"
        echo "   guest ok = $guest"
        
        [[ ${VETO:-yes} == no ]] || {
            echo -n "   veto files = /.apdisk/.DS_Store/.TemporaryItems/.Trashes/desktop.ini/ehthumbs.db/Network Trash Folder/Temporary Items/Thumbs.db/"
            echo "   delete veto files = yes"
        }
        
        [[ ${users:-""} && ! ${users:-""} == all ]] && echo "   valid users = $(tr ',' ' ' <<< "$users")"
        [[ ${admins:-""} && ! ${admins:-""} =~ none ]] && echo "   admin users = $(tr ',' ' ' <<< "$admins")"
        [[ ${writelist:-""} && ! ${writelist:-""} =~ none ]] && echo "   write list = $(tr ',' ' ' <<< "$writelist")"
        [[ ${comment:-""} && ! ${comment:-""} =~ none ]] && echo "   comment = $(tr ',' ' ' <<< "$comment")"
        echo ""
    } >> "$file"
    
    [[ -d $path ]] || mkdir -p "$path"
}

# Function to disable SMB2 minimum
smb() {
    local file="/etc/samba/smb.conf"
    
    sed -i 's/\([^#]*min protocol *=\).*/\1 LANMAN1/' "$file"
}

# Function to add a user
user() {
    local name="$1"
    local passwd="$2"
    local id="${3:-""}"
    local group="${4:-""}"
    local gid="${5:-""}"
    
    [[ "$group" ]] && grep -q "^$group:" /etc/group || addgroup ${gid:+--gid $gid }"$group"
    grep -q "^$name:" /etc/passwd || adduser -D -H ${group:+-G $group} ${id:+-u $id} "$name"
    echo -e "$passwd\n$passwd" | smbpasswd -s -a "$name"
}

# Function to set the workgroup
workgroup() {
    local workgroup="$1"
    local file="/etc/samba/smb.conf"
    
    sed -i 's|^\( *workgroup = \).*|\1'"$workgroup"'|' "$file"
}

# Function to allow wide symbolic links
widelinks() {
    local file="/etc/samba/smb.conf"
    local replace='\1\n   wide links = yes\n   unix extensions = no'
    
    sed -i 's/\(follow symlinks = yes\)/'"$replace"'/' "$file"
}

# Function to display usage information
usage() {
    local RC="${1:-0}"
    
    cat >&2 <<EOF
Usage: ${0##*/} [-opt] [command]
Options:
    -h          This help
    -c "<from:to>" setup character mapping for file/directory names
    -G "<section;parameter>" Provide generic section option for smb.conf
    -g "<parameter>" Provide global option for smb.conf
    -i "<path>" Import smbpassword
    -n          Start the 'nmbd' daemon to advertise the shares
    -p          Set ownership and permissions on the shares
    -r          Disable recycle bin for shares
    -S          Disable SMB2 minimum version
    -s "<name;/path>[;browse;readonly;guest;users;admins;writelist;comment]" Configure a share
    -u "<username;password>[;ID;group;GID]"       Add a user
    -w "<workgroup>"       Configure the workgroup (domain) samba should use
    -W          Allow access wide symbolic links
    -I          Add an include option at the end of the smb.conf

The 'command' (if provided and valid) will be run instead of samba
EOF
    exit "$RC"
}

[[ "${USERID:-""}" =~ ^[0-9]+$ ]] && usermod -u "$USERID" -o smbuser
[[ "${GROUPID:-""}" =~ ^[0-9]+$ ]] && groupmod -g "$GROUPID" -o smb

while getopts ":hc:G:g:i:nprs:Su:Ww:I:" opt; do
    case "$opt" in
        h) usage ;;
        c) charmap "$OPTARG" ;;
        G) eval generic $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$OPTARG") ;;
        g) global "$OPTARG" ;;
        i) import "$OPTARG" ;;
        n) NMBD="true" ;;
        p) PERMISSIONS="true" ;;
        r) recycle ;;
        s) eval share $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$OPTARG") ;;
        S) smb ;;
        u) eval user $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$OPTARG") ;;
        w) workgroup "$OPTARG" ;;
        W) widelinks ;;
        I) include "$OPTARG" ;;
        "?") echo "Unknown option: -$OPTARG"; usage 1 ;;
        ":") echo "No argument value for option: -$OPTARG"; usage 2 ;;
    esac
done
shift $(( OPTIND - 1 ))

# Apply environment variables as configuration options
[[ "${CHARMAP:-""}" ]] && charmap "$CHARMAP"
while read -r i; do
    eval generic $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$i")
done < <(env | awk '/^GENERIC[0-9=_]/ {sub (/^[^=]*=/, "", $0); print}')

while read -r i; do
    global "$i"
done < <(env | awk '/^GLOBAL[0-9=_]/ {sub (/^[^=]*=/, "", $0); print}')

[[ "${IMPORT:-""}" ]] && import "$IMPORT"
[[ "${RECYCLE:-""}" ]] && recycle

while read -r i; do
    eval share $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$i")
done < <(env | awk '/^SHARE[0-9=_]/ {sub (/^[^=]*=/, "", $0); print}')

[[ "${SMB:-""}" ]] && smb

while read -r i; do
    eval user $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< "$i")
done < <(env | awk '/^USER[0-9=_]/ {sub (/^[^=]*=/, "", $0); print}')

[[ "${WORKGROUP:-""}" ]] && workgroup "$WORKGROUP"
[[ "${WIDELINKS:-""}" ]] && widelinks
[[ "${INCLUDE:-""}" ]] && include "$INCLUDE"
[[ "${PERMISSIONS:-""}" ]] && perms &

# Run the specified command or start the Samba services
if [[ $# -ge 1 && -x "$(command -v "$1" 2>/dev/null)" ]]; then
    exec "$@"
elif [[ $# -ge 1 ]]; then
    echo "ERROR: command not found: $1"
    exit 13
elif pgrep -f smbd >/dev/null; then
    echo "Service already running, please restart container to apply changes"
else
    [[ ${NMBD:-""} ]] && ionice -c 3 nmbd -D
    exec ionice -c 3 smbd -FS --no-process-group </dev/null
fi
