#!/bin/bash

## Purpose: Create a 2GB file at $PGDATA/.. 
##    so that if the system unexpectedly fills up, you can buy yourself
##    some breathing room to clear up space.
##
## Usage:
#   cd to the volume where you want to add the 2GB file
#
#dd if=/dev/zero of=remove_me_when_space_is_needed bs=1024 count=2000000

# To create a 2GB "removeme" file:
dir=/path/above/$DATADIR
file=remove_me_when_space_is_needed
dfree=$(echo $(($(stat -f --format="%a*%S" "$dir")/10**6)))
if [ "$dfree" -gt 10000 ]; then
    ## At least 10GB free
    if [ ! -e "${dir}/${file}" ]; then
        fallocate -l 2G "${dir}/${file}"
    fi
fi

