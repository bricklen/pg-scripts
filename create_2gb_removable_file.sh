#!/bin/bash

## Purpose: Create a 2GB file under $PGDATA/ and one under $PGDATA/pg_xlog/
##    so that if the system unexpectedly fills up, at least you can buy yourself
##    some breathing room, or at least, for as long as it takes for the space
##    to be reclaimed...
##
## Usage:
##   cd to the volume where you want to add the 2GB file

dd if=/dev/zero of=remove_me_when_space_is_needed bs=1024 count=2000000

