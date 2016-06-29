# live-profile-monitor

It is client side library for live eventlog profiling toolchain. The library collects data from
eventlog and sends it via UDP or TCP to remote profiling tool.

The repo is related to the Haskell Summer of Code 2016 [project](http://ncrashed.github.io/blog/posts/2016-06-12-hsoc-acceptance.html). The tool is currently requires hacked RTS (see below) to 
operate properly.

# How to build 

* You need a patched GHC 8.1 from [the repo](https://github.com/NCrashed/ghc) until the project is merged into
GHC master.

* Clone and boot the repo: 
```
git clone https://github.com/NCrashed/live-profile-monitor.git
cd bar
git submodule update --init --recursive
```

* Initalize cabal environment (note, you need `Cabal` and `cabal-install` not lower than `1.24.0.0` version):
```
cabal new-configure --enable-tests
```

* Compile:
```
cabal new-build
```

* Test:
```
./tests.sh
```