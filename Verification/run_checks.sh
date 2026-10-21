#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
mkdir -p build/module-cache
export CLANG_MODULE_CACHE_PATH="$project_root/build/module-cache"
export SWIFT_MODULECACHE_PATH="$project_root/build/module-cache"
export PYTHONDONTWRITEBYTECODE=1
swiftc -swift-version 5 -parse-as-library MotionCore/*.swift Verification/ProjectChecks.swift -o build/project-checks
build/project-checks
python3 -m unittest discover -s Verification -p 'test_*.py' -v
