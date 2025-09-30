#!/bin/bash
# 请把本文件复制到你需要的位置，
# 并在home目录的.bashrc末尾添加source /path/of/cangjie.sh
export CJPM_CONFIG=/mnt/d/docs/work/cangjie/repository

cangjie_version(){
  echo "$ lsb_release -a"
  lsb_release -a
  echo
  echo "$ uname -a"
  uname -a
  echo
  echo "$ cjc -v"
  cjc -v
  echo
  echo '$ echo $CANGJIE_HOME'
  echo $CANGJIE_HOME
  echo
  echo '$ echo $CANGJIE_STDX_DYNAMIC_PATH'
  echo $CANGJIE_STDX_DYNAMIC_PATH
  echo
  echo '$ ls $CANGJIE_STDX_DYNAMIC_PATH'
  ls $CANGJIE_STDX_DYNAMIC_PATH
  echo '$ ls $CANGJIE_FOUNTAIN_LIBS'
  ls $CANGJIE_FOUNTAIN_LIBS
  echo
}
cangjie_env(){
  export CANGJIE_STDX_PATH=/mnt/d/docs/work/cangjie/stdx/$2/linux_x86_64_llvm
  export CANGJIE_STDX_DYNAMIC_PATH=$CANGJIE_STDX_PATH/dynamic/stdx
  export CANGJIE_STDX_STATIC_PATH=$CANGJIE_STDX_PATH/static/stdx
  export CANGJIE_HOME=/mnt/d/docs/work/cangjie/cangjie-linux-bin/$1
  export LD_LIBRARY_PATH=/usr/local/openssl-3.3.2/lib:$CANGJIE_STDX_PATH/dynamic/stdx:/mnt/d/docs/work/cangjie/installed/libs/fboot:$LD_LIBRARY_PATH
  export PATH=$PATH:/mnt/d/docs/work/cangjie/installed/bin
  export CANGJIE_FOUNTAIN_LIBS=/mnt/d/docs/work/cangjie/installed/libs/fboot
  source $CANGJIE_HOME/envsetup.sh
}
cj(){
  echo "cj $1 $2 $3"
  case "$1" in
  env)
    cangjie_env $2 $3
    ;;
  version)
    cangjie_version
    ;;
  cleanUpdate)
    fboot cleanUpdate
    ;;
  install)
    fboot replaceVersion ./
    cd fboot
    cjpm install --root /mnt/d/docs/work/cangjie/installed
    ;;
  installed)
    cd /mnt/d/docs/work/cangjie/installed
    ;;
  study)
    cd /mnt/d/docs/work/cangjie/study
    ;;
  fountain)
    cd /mnt/d/docs/work/cangjie/projects/fountain
    ;;
  fboot)
    cd /mnt/d/docs/work/cangjie/projects/fountain/fboot
    ;;
  fdemo)
    cd /mnt/d/docs/work/cangjie/projects/fountain/fdemo
    ;;
  '-c')
    f=$2
    cf=${f%.cj*}
    cjc $f -o $cf && ./$cf
    ;;
  esac
}

cj env 1.0.0 1.0.1.1
