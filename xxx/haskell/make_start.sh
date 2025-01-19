#!/bin/bash

#grep-dctrl -v -F Maintainer "Debian Haskell Group" orig/Packages-all > Packages-all.start
#/srv/wanna-build/bin/keep-latest amd64 Packages-amd64.start > Packages-amd64.start-latest
grep-dctrl -v -F Maintainer "Debian Haskell Group" orig/Packages-amd64 > Packages-amd64.start
grep-dctrl -F Maintainer "Debian Haskell Group" orig/Packages-amd64 > Packages-amd64.Haskell

cp Packages-amd64.start Packages-amd64
cp orig/Sources .

parallel -l 2 -i wanna-build -v --Pas /srv/wanna-build/etc/Packages-arch-specific --merge-v3 -A {} --dist=sid Packages-amd64 . Sources -- all amd64

