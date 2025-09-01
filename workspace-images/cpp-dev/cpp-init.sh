#!/usr/bin/env bash
set -eu

log() { printf '[cpp-init] %s\n' "$*"; }

log "Setting up C++ development environment"

# Create necessary directories
log "Creating development directories"
mkdir -p /home/coder/projects/cpp
mkdir -p /home/coder/.cache/ccache
mkdir -p /home/coder/.local/share/cpp-templates
chown -R coder:coder /home/coder/projects /home/coder/.cache /home/coder/.local

# Add C++ development helper functions to bashrc (idempotent)
if ! grep -q "# --- C++ development helpers ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- C++ development helpers ---
# Helper to create a new C++ project with CMake
create-cpp() {
    local project_name="${1:-my-cpp-project}"
    local use_vcpkg="${2:-yes}"
    
    echo "Creating C++ project: $project_name"
    echo "Using vcpkg: $use_vcpkg"
    
    mkdir -p "$project_name"
    cd "$project_name"
    
    # Create basic CMakeLists.txt
    cat > CMakeLists.txt <<CMAKE_EOF
cmake_minimum_required(VERSION 3.20)
project($project_name VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Add compiler warnings
if(MSVC)
    add_compile_options(/W4)
else()
    add_compile_options(-Wall -Wextra -Wpedantic)
endif()
CMAKE_EOF

    if [[ "$use_vcpkg" == "yes" ]]; then
        cat >> CMakeLists.txt <<CMAKE_EOF

# vcpkg integration
if(DEFINED ENV{VCPKG_ROOT} AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    set(CMAKE_TOOLCHAIN_FILE "\$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake"
        CACHE STRING "")
endif()
CMAKE_EOF
        
        # Create vcpkg.json
        cat > vcpkg.json <<VCPKG_EOF
{
    "name": "$project_name",
    "version": "1.0.0",
    "dependencies": [
        "fmt",
        "spdlog",
        "catch2"
    ]
}
VCPKG_EOF
    fi


    # Add executable
    cat >> CMakeLists.txt <<CMAKE_EOF

# Add executable
add_executable(\${PROJECT_NAME} src/main.cpp)
CMAKE_EOF

    if [[ "$use_vcpkg" == "yes" ]]; then
        cat >> CMakeLists.txt <<CMAKE_EOF

# Find packages
find_package(fmt CONFIG REQUIRED)
find_package(spdlog CONFIG REQUIRED)

# Link libraries
target_link_libraries(\${PROJECT_NAME} PRIVATE fmt::fmt spdlog::spdlog)
CMAKE_EOF
    fi


    # Create source directory and main.cpp
    mkdir -p src
    cat > src/main.cpp <<CPP_EOF
#include <iostream>
#include <string>

int main(int argc, char* argv[]) {
    std::cout << "Hello, C++20 World!" << std::endl;
    
    if (argc > 1) {
        std::cout << "Arguments provided:" << std::endl;
        for (int i = 1; i < argc; ++i) {
            std::cout << "  " << i << ": " << argv[i] << std::endl;
        }
    }
    
    return 0;
}
CPP_EOF

    # Create .gitignore
    cat > .gitignore <<GIT_EOF
# Build directories
build/
cmake-build-*/

# IDE files
.vscode/
.idea/
*.swp
*.swo

# Compiler outputs
*.o
*.a
*.so
*.dll
*.exe

# CMake
CMakeCache.txt
CMakeFiles/
cmake_install.cmake
Makefile

# Conan
conandata.yml
conaninfo.txt
conanbuildinfo.*

# vcpkg
vcpkg_installed/
GIT_EOF

    # Create README.md
    cat > README.md <<README_EOF
# $project_name

A C++20 project created with modern tooling.

## Building

### Using CMake directly:
\`\`\`bash
mkdir build && cd build
cmake .. -G Ninja
ninja
\`\`\`

### Using helper commands:
\`\`\`bash
cpp-build      # Configure and build
cpp-run        # Build and run
cpp-test       # Build and run tests
cpp-clean      # Clean build directory
\`\`\`
README_EOF

    echo "✨ C++ project '$project_name' created successfully!"
    echo "📁 Project structure created with CMake, source files, and build configuration"
    
    if [[ "$use_vcpkg" == "yes" ]]; then
        echo "📦 vcpkg configuration ready - run 'vcpkg install' to install dependencies"
    fi
}

# Helper to build C++ project
cpp-build() {
    if [[ ! -f "CMakeLists.txt" ]]; then
        echo "❌ No CMakeLists.txt found. Are you in a C++ project directory?"
        return 1
    fi
    
    mkdir -p build
    cd build
    cmake .. -G Ninja
    
    ninja
    cd ..
}

# Helper to run C++ project
cpp-run() {
    cpp-build
    if [[ -f "build/$PWD" ]]; then
        ./build/"$(basename "$PWD")"
    else
        echo "❌ Executable not found after build"
    fi
}

# Helper to run tests
cpp-test() {
    cpp-build
    cd build
    ctest --verbose
    cd ..
}

# Helper to clean build
cpp-clean() {
    if [[ -d "build" ]]; then
        rm -rf build
        echo "🧹 Build directory cleaned"
    else
        echo "No build directory to clean"
    fi
}

# Helper to format code
cpp-format() {
    find . -name "*.cpp" -o -name "*.h" -o -name "*.hpp" | xargs clang-format -i
    echo "✨ Code formatted with clang-format"
}

# Helper to analyze code
cpp-analyze() {
    if [[ -f "CMakeLists.txt" ]]; then
        echo "🔍 Running static analysis with clang-tidy..."
        find src -name "*.cpp" | xargs clang-tidy -p build/
    else
        echo "❌ No CMakeLists.txt found"
    fi
}

# Available development tasks
cpp-tasks() {
    echo "Available C++ development tasks:"
    echo "  cpp-build        - Configure and build with CMake + Ninja"
    echo "  cpp-run          - Build and run executable"
    echo "  cpp-test         - Build and run tests"
    echo "  cpp-clean        - Clean build directory"
    echo "  cpp-format       - Format code with clang-format"
    echo "  cpp-analyze      - Static analysis with clang-tidy"
    echo ""
    echo "Project creation:"
    echo "  create-cpp [name] [vcpkg] - Create new C++ project"
    echo ""
    echo "Package manager:"
    echo "  vcpkg install    - Install vcpkg dependencies"
}

# Compiler shortcuts
alias gcc-debug='g++ -g -O0 -DDEBUG'
alias gcc-release='g++ -O3 -DNDEBUG'  
alias clang-debug='clang++ -g -O0 -DDEBUG'
alias clang-release='clang++ -O3 -DNDEBUG'

# Build shortcuts
alias cmake-debug='cmake -DCMAKE_BUILD_TYPE=Debug -G Ninja'
alias cmake-release='cmake -DCMAKE_BUILD_TYPE=Release -G Ninja'
alias ninja-verbose='ninja -v'

# Analysis shortcuts
alias valgrind-check='valgrind --tool=memcheck --leak-check=full'
alias gdb-run='gdb --args'
# ---
EOF
fi

# Set up common project templates
log "Setting up project templates"
TEMPLATES_DIR="/home/coder/.local/share/cpp-templates"
mkdir -p "$TEMPLATES_DIR"

# Create header template
cat > "$TEMPLATES_DIR/header.hpp.template" <<'EOF'
#pragma once

#include <iostream>
#include <string>
#include <vector>
#include <memory>

namespace {{namespace}} {

class {{ClassName}} {
public:
    {{ClassName}}() = default;
    ~{{ClassName}}() = default;
    
    // Copy constructor and assignment
    {{ClassName}}(const {{ClassName}}& other) = default;
    {{ClassName}}& operator=(const {{ClassName}}& other) = default;
    
    // Move constructor and assignment  
    {{ClassName}}({{ClassName}}&& other) noexcept = default;
    {{ClassName}}& operator=({{ClassName}}&& other) noexcept = default;

private:
    // Member variables
};

} // namespace {{namespace}}
EOF

# Create source template
cat > "$TEMPLATES_DIR/source.cpp.template" <<'EOF'
#include "{{header_name}}.hpp"

namespace {{namespace}} {

// Implementation here

} // namespace {{namespace}}
EOF

chown -R coder:coder "$TEMPLATES_DIR"

# Configure C++ environment variables in bashrc (idempotent)
if ! grep -q "CMAKE_GENERATOR" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- C++ development environment ---
export CC=gcc
export CXX=g++
export CMAKE_GENERATOR=Ninja
export CMAKE_EXPORT_COMPILE_COMMANDS=ON
export VCPKG_ROOT=/opt/vcpkg
export PATH="$PATH:/opt/vcpkg"
export PATH="/usr/lib/ccache:$PATH"
# ---
EOF
fi

# Set up default clang-format configuration
log "Setting up code formatting configuration"
cat > /home/coder/.clang-format <<'EOF'
BasedOnStyle: Google
IndentWidth: 4
TabWidth: 4
UseTab: Never
ColumnLimit: 100
AccessModifierOffset: -2
IndentCaseLabels: true
SpacesBeforeTrailingComments: 2
Standard: c++20
EOF

# Create useful aliases and shortcuts in bashrc (idempotent)
if ! grep -q "# --- C++ shortcuts ---" /home/coder/.bashrc; then
    cat >> /home/coder/.bashrc <<'EOF'

# --- C++ shortcuts ---
# Quick project navigation
alias cpp-proj='cd ~/projects/cpp'

# Compilation shortcuts
alias compile='g++ -std=c++20 -Wall -Wextra'
alias compile-debug='g++ -std=c++20 -Wall -Wextra -g -O0 -DDEBUG'
alias compile-release='g++ -std=c++20 -Wall -Wextra -O3 -DNDEBUG'

# CMake shortcuts  
alias cmake-config='cmake -B build -G Ninja'
alias cmake-build='cmake --build build'
alias cmake-install='cmake --install build'

# Package manager shortcuts
alias vcpkg-search='vcpkg search'
alias vcpkg-list='vcpkg list'
# ---
EOF
fi

# Ensure ownership of all created files
chown -R coder:coder /home/coder/.bashrc /home/coder/.local /home/coder/.cache /home/coder/.clang-format 2>/dev/null || true


log "C++ development environment setup complete"
log "Use 'create-cpp [project-name]' to create a new C++ project"
log "Use 'cpp-tasks' to see available development commands"