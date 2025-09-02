FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bullseye-20241202 AS builder

# Install build dependencies
RUN apt-get update && \
    apt-get install -y build-essential git curl cargo rustc wget && \
    rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# Build Gleam from source
RUN git clone --depth 1 --branch v1.12.0 https://github.com/gleam-lang/gleam.git /tmp/gleam && \
    cd /tmp/gleam && \
    cargo build --release && \
    cp target/release/gleam /usr/local/bin/gleam && \
    rm -rf /tmp/gleam

# Install rebar3
RUN wget https://github.com/erlang/rebar3/releases/download/3.24.0/rebar3 && \
    chmod +x rebar3 && \
    mv rebar3 /usr/local/bin/

# Setup Elixir
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy and build
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY . .
RUN rm -rf build _build && gleam build --target erlang

# Runtime
FROM hexpm/elixir:1.17.3-erlang-27.2-debian-bullseye-20241202

RUN apt-get update && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8

WORKDIR /app

# Copy app and gleam binary
COPY --from=builder /app /app
COPY --from=builder /usr/local/bin/gleam /usr/local/bin/gleam
COPY --from=builder /usr/local/bin/rebar3 /usr/local/bin/rebar3

# Setup Elixir in runtime too
RUN mix local.hex --force && mix local.rebar --force

ENV BIND_ADDRESS=0.0.0.0
EXPOSE 8080
CMD ["gleam", "run"]

