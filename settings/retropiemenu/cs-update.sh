#!/bin/bash
# EmulationStation "RetroPie" menu entry — Circuit Sword Updater.
#
# Named .sh (NOT .rp) on purpose: the RetroPie retropiemenu launcher maps *.rp
# entries to RetroPie-Setup scriptmodules and ignores their file content, but it
# runs *.sh entries directly (`sudo -u <user> bash`, with joy2key started). So a
# custom launcher must be a .sh. cs-update runs its UI as the user and elevates
# itself only for the actual install.
exec /usr/local/bin/cs-update menu
