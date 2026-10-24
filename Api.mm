name: Build Neko Final
on: [push, workflow_dispatch]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Theos via Action
        uses: Randomblock1/theos-action@v1
        with:
          theos-dir: 'theos'
          theos-src: 'https://github.com/theos/theos'
          theos-sdks: 'https://github.com/theos/sdks'
          theos-sdks-branch: 'master'
          
      - name: Create SDK Directory (Fix for previous error)
        run: mkdir -p $GITHUB_WORKSPACE/theos/sdks
          
      - name: Download iOS SDK
        run: |
          rm -rf $GITHUB_WORKSPACE/theos/sdks
          git clone --depth 1 https://github.com/theos/sdks.git $GITHUB_WORKSPACE/theos/sdks
          
      - name: Compile Luau
        run: |
          git clone --depth 1 https://github.com/luau-lang/luau vendor/luau-src
          cd vendor/luau-src
          mkdir -p ../../vendor/luau/lib ../../vendor/luau/include
          
          SDK_PATH=$(find $GITHUB_WORKSPACE/theos/sdks -name "iPhoneOS*.sdk" | sort -V | tail -n 1)
          INCLUDES=$(find . -type d -name "include" | sed 's/^/-I/' | tr '\n' ' ')
          
          mkdir -p build_vm
          for f in VM/src/*.cpp; do
            clang++ -isysroot "$SDK_PATH" -target arm64-apple-ios15.0 -std=c++17 -stdlib=libc++ -O3 $INCLUDES -c "$f" -o "build_vm/$(basename $f).o"
          done
          ar rcs ../../vendor/luau/lib/Luau.VM.a build_vm/*.o
          
          mkdir -p build_compiler
          for f in Compiler/src/*.cpp; do
            clang++ -isysroot "$SDK_PATH" -target arm64-apple-ios15.0 -std=c++17 -stdlib=libc++ -O3 $INCLUDES -c "$f" -o "build_compiler/$(basename $f).o"
          done
          ar rcs ../../vendor/luau/lib/Luau.Compiler.a build_compiler/*.o
          
          for d in $(find . -type d -name "include"); do
            cp -r $d/* ../../vendor/luau/include/ 2>/dev/null || true
          done
          
      - name: Build Neko Tweak
        run: |
          export THEOS=$GITHUB_WORKSPACE/theos
          export PATH=$THEOS/bin:$PATH
          make clean
          make
          
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: neko-dylib-final
          path: .theos/obj/debug/neko.dylib
