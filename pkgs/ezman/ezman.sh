#!/usr/bin/env bash

# Color codes
BLUE='\033[1;34m'
NC='\033[0m' # No Color

BASE_OPTION=$1

if [ -z "$BASE_OPTION" ]; then
    echo "Usage: $0 <option.path>"
    exit 1
fi

inspect_recursive() {
    local path=$1
    
    # Run nixos-option and hide Git warnings/errors
    RESULT=$(nixos-option "$path" 2>/dev/null)
    
    if echo "$RESULT" | grep -q "Value:"; then
        # Back to [ OPTION ] with color
        echo -e "${BLUE}[ OPTION ]${NC} $path"
        
        # 1. Only look at the block from 'Value:' to the footer
        # 2. Delete the footer line itself
        # 3. Match 'Declared by:' or 'Defined by:', pull the next line (N), and delete (d)
        # 4. Squeeze extra empty lines
        echo "$RESULT" | sed -n '/Value:/,/This attribute set contains:/p' \
            | sed '/This attribute set contains:/d' \
            | sed '/Declared by:/{N;d;}' \
            | sed '/Defined by:/{N;d;}' \
            | sed '/^[[:space:]]*$/d'
            
        echo "------------------------------------------------"
    fi
    
    # Extract sub-options for recursion using sed
    CHILDREN=$(echo "$RESULT" | sed -n '/This attribute set contains:/,$p' | sed '1d' | sed 's/[[:space:]].*//')

    for child in $CHILDREN; do
        inspect_recursive "$path.$child"
    done
}

inspect_recursive "$BASE_OPTION"
