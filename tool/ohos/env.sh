# Environment for building the HarmonyOS app. Source it:
#   source tool/ohos/env.sh
# Paths are this machine's defaults; set FLUTTER_OHOS_ROOT, DEVECO_HOME or
# JAVA_HOME before sourcing to change them.
export FLUTTER_OHOS_ROOT="${FLUTTER_OHOS_ROOT:-$HOME/vscode-project/flutter_ohos}"
export TOOL_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export DEVECO_SDK_HOME="$TOOL_HOME/sdk"
export JAVA_HOME="${JAVA_HOME:-/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home}"
export PATH="$FLUTTER_OHOS_ROOT/bin:$TOOL_HOME/tools/ohpm/bin:$TOOL_HOME/tools/hvigor/bin:$TOOL_HOME/tools/node/bin:$PATH"
export HDC="$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc"
# Some ports keep large example files in Git LFS and the objects are missing
# from the remote (flutter_audio_session's example/ohos/dta/icudtl.dat); pub's
# checkout of the package fails on them unless LFS files are left as pointers.
export GIT_LFS_SKIP_SMUDGE=1
