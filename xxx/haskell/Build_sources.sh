#!/bin/bash -x

#STAGE=$1

#wanna-build -d sid -A all --list needs-build | tee stage${STAGE}_all
#wanna-build -d sid -A amd64 --list needs-build | tee stage${STAGE}_amd64

#cat stage${STAGE}_all stage${STAGE}_amd64 >> stage${STAGE}

#> stage${STAGE}_packages

#sed 's|^.*/\(.*\)_.*$|\1|' stage${STAGE} | sort -u > stage${STAGE}_sources

#for package in $(cat stage${STAGE}_sources) ; do

#  grep-dctrl -S $package ../1/Packages >> stage${STAGE}_packages

#done

#[ -s stage${STAGE}_packages ] && cat stage${STAGE}_packages >> Packages

#parallel -l 2 -i wanna-build -v --Pas /srv/wanna-build/etc/Packages-arch-specific --merge-v3 -A {} --dist=sid Packages-amd64 . Sources -- all amd64

#grep-dctrl ( -X -S haskell-devscripts -a -F Version 0.16.34 ) --or ( -X -S haskell-devscripts (0.16.34) ) orig/Packages-amd64
#grep-dctrl \( -X -S ghc -a -F Version 9.6.6-3 \) --or \( -X -S "ghv (9.6.6-3)" \) orig/Packages-amd64 > packages/ghc.cp

STAGE=$1
wanna-build -d sid -A amd64 --list needs-build | grep -v "Total" | sed 's/ .*$//' > stages/stage${STAGE}-amd64
wanna-build -d sid -A all --list needs-build   | grep -v "Total" | sed 's/ .*$//' > stages/stage${STAGE}-all

[ -f stages/status ] || touch status

echo ">>> AMD64"
for line in $( cat stages/stage${STAGE}-amd64 ) ; do
  package=$(echo $line | sed 's#^.*/\(.*\)_.*$#\1#')
  version=$(echo $line | sed 's#^.*_\(.*\)$#\1#')

  echo "${package} -> ${version}"

  X=$(ls -1 packages/${package}_*-amd64.cp 2>/dev/null)
  if [ ! -z "${X}" ] ; then
    echo "Пакет уже компилировался!!!!"
    echo "-------"
    echo $X
    echo "-------"
    continue
  fi
  grep-dctrl -F Architecture amd64 --and \( \( -X -S ${package} -a -F Version ${version} \) --or \
                 \( -X -S "${package} (${version})" \) \) orig/Packages-amd64 > packages/${package}_stage${STAGE}-amd64.cp
  X=$(grep ${package} stages/status)
  if [ -z "${X}" ] ; then
     echo "New stage for adaptation"
     echo "${package}" >> stages/stage${STAGE}
     echo "${package}" >> stages/status
  fi
done

echo ">>> ALL"
for line in $( cat stages/stage${STAGE}-all ) ; do
  package=$(echo $line | sed 's#^.*/\(.*\)_.*$#\1#')
  version=$(echo $line | sed 's#^.*_\(.*\)$#\1#')

  echo "${package} -> ${version}"
  X=$(ls -1 packages/${package}_*-all.cp 2>/dev/null)
  if [ ! -z "${X}" ] ; then
    echo "Пакет уже компилировался!!!!"
    echo "-------"
    echo $X
    echo "-------"
    continue
  fi
  grep-dctrl -F Architecture all --and \( \( -X -S ${package} -a -F Version ${version} \) --or \
                 \( -X -S "${package} (${version})" \) \) orig/Packages-amd64 > packages/${package}_stage${STAGE}-all.cp
  X=$(grep ${package} stages/status)
  if [ -z "${X}" ] ; then
     echo "New stage for adaptation"
     echo "${package}" >> stages/stage${STAGE}
     echo "${package}" >> stages/status
  fi
done

cat  Packages-amd64.start packages/*.cp > Packages-amd64
parallel -l 2 -i wanna-build -v --Pas /srv/wanna-build/etc/Packages-arch-specific --merge-v3 -A {} --dist=sid Packages-amd64 . Sources -- all amd64

echo "AMD64"
wanna-build -d sid -A amd64 --list needs-build

echo "ALL"
wanna-build -d sid -A all --list needs-build
