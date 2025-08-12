# Development Dockerfile for TrackTags - Gleam 1.12
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bullseye-20241202

# Install build dependencies
RUN apt-get update && \
    apt-get install -y \
        build-essential \
        git \
        curl \
        cargo \
        rustc \
        wget && \
    rm -rf /var/lib/apt/lists/*

# Install modern Rust via rustup (needed for Gleam 1.12)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Build Gleam 1.12.0 from source (CRITICAL - must be 1.12!)
RUN git clone --depth 1 --branch v1.12.0 https://github.com/gleam-lang/gleam.git /tmp/gleam && \
    cd /tmp/gleam && \
    cargo build --release && \
    cp target/release/gleam /usr/local/bin/gleam && \
    rm -rf /tmp/gleam

# Install rebar3
RUN wget https://github.com/erlang/rebar3/releases/download/3.24.0/rebar3 && \
    chmod +x rebar3 && \
    mv rebar3 /usr/local/bin/

WORKDIR /workspace

# Copy project files
COPY . .

# Install Gleam dependencies and build
RUN gleam deps download && \
    gleam build --target erlang

# Expose the port
EXPOSE 4001

# Default command for development
CMD ["gleam", "run"]
