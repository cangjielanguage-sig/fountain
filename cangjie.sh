#!/bin/bash
# 并在home目录的.bashrc末尾添加source /path/of/cangjie.sh
# Please copy this file to the location you need,
# and add 'source /path/of/cangjie.sh' to the end of ~/.bashrc

export CANGJIE_HOME=$( cd -- "$( dirname -- "${BASH_SOURCE}" )" &> /dev/null && pwd -P )
export FOUNTAIN_HOME=$CANGJIE_HOME/projects/fountain

cangjie_version(){
  echo '### 系统环境'
  echo '```bash'
  echo "$ lsb_release -a"
  lsb_release -a
  echo
  echo "$ uname -a"
  uname -a
  echo
  echo "$ cjc -v"
  cjc -v
  echo
  echo '$ echo $CANGJIE_STDX_DYNAMIC_PATH'
  echo $CANGJIE_STDX_DYNAMIC_PATH
  echo '```'
  STDX_VERSION=`echo $CANGJIE_STDX_DYNAMIC_PATH|awk -F'/' '{print $8}'`
  echo '
### 问题描述
```bash
git clone https://gitcode.com/Cangjie-SIG/fountain.git
cd fountain'
echo "git checkout -t origin/issue/<CurrentIssueID>" \# '把<CurrentIssueID>换成当前issue的ID'
echo 'cd fboot'
echo "export CANGJIE_STDX_DYNAMIC_PATH=/path/of/stdx/$STDX_VERSION/linux_x86_64_llvm/dynamic/stdx"
echo '
cjpm install --root ../installed
cd ../installed
CJPM_INSTALL=`pwd`
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$CJPM_INSTALL/libs/fboot
export PATH=$PATH:$CJPM_INSTALL/bin
cd ../fdemo
./boot.sh build
```
'
#  echo '$ echo $CANGJIE_HOME'
#  echo $CANGJIE_HOME
#  echo
#  echo '$ echo $CANGJIE_STDX_DYNAMIC_PATH'
#  echo $CANGJIE_STDX_DYNAMIC_PATH
#  echo
#  echo '$ ls $CANGJIE_STDX_DYNAMIC_PATH'
#  ls $CANGJIE_STDX_DYNAMIC_PATH
#  echo '$ ls $CANGJIE_FOUNTAIN_LIBS'
#  ls $CANGJIE_FOUNTAIN_LIBS
  echo
}
cangjie_env(){
  export CJPM_CONFIG=/mnt/d/docs/work/cangjie/repository
  export CJPM_INSTALL=/mnt/d/docs/work/cangjie/installed
  export CANGJIE_STDX_PATH=/mnt/d/docs/work/cangjie/cangjie-linux-bin/stdx/$2/linux_x86_64_cjnative
  export CANGJIE_STDX_DYNAMIC_PATH=$CANGJIE_STDX_PATH/dynamic/stdx
  export CANGJIE_STDX_STATIC_PATH=$CANGJIE_STDX_PATH/static/stdx
  export CANGJIE_FOUNTAIN_LIBS=$CJPM_INSTALL/libs/fboot
  export CANGJIE_HOME=/mnt/d/docs/work/cangjie/cangjie-linux-bin/sdk/$1/cangjie
  export LD_LIBRARY_PATH=/usr/local/openssl-3.3.2/lib:$CANGJIE_FOUNTAIN_LIBS:$LD_LIBRARY_PATH
  export PATH=$PATH:$CJPM_INSTALL/bin:$CANGJIE_HOME/third_party/llvm/lldb/bin
  source $CANGJIE_HOME/envsetup.sh
  rm -f /mnt/d/docs/work/cangjie/cangjie-linux-bin/sdk/current/cangjie
  rm -f /mnt/d/docs/work/cangjie/cangjie-linux-bin/sdk/current
  ln -s $CANGJIE_HOME /mnt/d/docs/work/cangjie/cangjie-linux-bin/sdk/current
  cp ~/.cjpm/tools/config/*.json $CANGJIE_HOME/tools/config/
  cjc -v
}

cjsetup(){
  declare -A map
  map['sdk_x64-1.1.0-beta.23']='https://cangjie-lang.cn/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-linux-x64-1.1.0-beta.23.tar.gz&objectKey=69b7a52a6e8ed61e6e07fd2c'
  map['stdx_x64-1.1.0-beta.23.1']='https://gitcode.com/Cangjie/cangjie_stdx/releases/download/v1.1.0-beta.23.1/cangjie-stdx-linux-x64-1.1.0-beta.23.1.zip'
  arch=$1
  version=$2
  url=map["sdk_$arch-$version"]
  target=${CANGJIE_HOME:-"~/.cjpm/home"}
  path=$target/sdk/$version
  mkdir -p $path
  cd $path
  wget $url
  tar zxf *.tar.gz
  rm *.tar.gz
  version=$3
  path=$target/stdx/$version
  mkdir -p $path
  cd path
  url=map["stdx_$arch-$version"]
  wget $url
  unzip *.zip
  rm -f *.zip
  cj env $2 $3
}
cj(){
  echo "cj $1 $2 $3 $4 $5"
  case "$1" in
  env)
    cangjie_env $2 $3
    ;;
  version)
    cangjie_version $2
    ;;
  cleanUpdate)
    fboot cleanUpdate
    ;;
  install)
    fboot version $2 $3 $4 $5
    cd fboot
    cjpm install --root $CJPM_INSTALL
    echo -e "\a"
    cd ..
    ;;
  installed)
    cd $CJPM_INSTALL
    ;;
  publish)
    sed -E "s/fountain\([0-9]+\.[0-9]+\.[0-9]+\)/fountain($1)/g" ./f_version/src/FountainVersion.cj
    fboot pub $1
    git add .
    git commit -m"升级版本：$1"
    ;;
  setup)
    cjsetup $3 $4
    ;;
  study)
    cd /mnt/d/docs/work/cangjie/study
    ;;
  fountain)
    cd $FOUNTAIN_HOME
    if [[ "$2" == "install" ]]; then                                                                                 
        cj install
    elif [ -n "$2" ]; then                                                                                           
	cd $2
    fi
    ;;
  fboot)
    cd $FOUNTAIN_HOME/fboot
    ;;
  fdemo)
    cd $FOUNTAIN_HOME/fdemo
    ;;
  cj)
    cd /mnt/d/docs/work/cangjie/$2
    ;;
  '-c')
    f=$2
    cf=${f%.cj*}
    cjc $f -o $cf && ./$cf
    ;;
  esac
}

cj env 1.1.0 1.1.0
