# Extends YOUR base image
ARG BASE_IMAGE=us-central1-docker.pkg.dev/coder-nt/workspace-images/base-dev:latest
FROM ${BASE_IMAGE}

USER root

# Install C++ development tools and compilers
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    # Core C++ development
    build-essential g++ gcc clang clang-format clang-tidy \
    # Development tools
    gdb valgrind lldb \
    # Build systems
    cmake ninja-build make autotools-dev automake \
    # Package managers and dependency management
    pkg-config \
    # vcpkg dependencies
    zip unzip tar \
    # Libraries and frameworks
    libboost-all-dev \
    libgtest-dev libgmock-dev \
    libfmt-dev \
    libbenchmark-dev \
    # Networking and system libraries
    libssl-dev libcurl4-openssl-dev \
    # Database libraries
    libsqlite3-dev \
    # JSON libraries
    nlohmann-json3-dev \
    # Additional utilities
    doxygen graphviz \
    cppcheck \
    # Version control integration
    gitk git-gui \
 && rm -rf /var/lib/apt/lists/*

# Install vcpkg (C++ package manager)
RUN git clone https://github.com/Microsoft/vcpkg.git /opt/vcpkg \
 && /opt/vcpkg/bootstrap-vcpkg.sh \
 && ln -s /opt/vcpkg/vcpkg /usr/local/bin/vcpkg

# Create C++-specific init script
COPY cpp-init.sh /usr/local/share/workspace-init.d/20-cpp-init.sh
RUN chmod +x /usr/local/share/workspace-init.d/20-cpp-init.sh

# Copy C++ project scaffolds
COPY ../../project-scaffolds/cpp /opt/coder-scaffolds/

# Set C++ environment variables
ENV CC=gcc
ENV CXX=g++
ENV CMAKE_GENERATOR=Ninja
ENV VCPKG_ROOT=/opt/vcpkg
ENV PATH=$PATH:/opt/vcpkg

USER coder

# Create C++ development directories
RUN mkdir -p /home/coder/projects/cpp \
 && mkdir -p /home/coder/.cache/ccache

# Set up ccache for faster builds
RUN echo 'export PATH="/usr/lib/ccache:$PATH"' >> /home/coder/.bashrc