import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}
import gleam/string

// ============================================================================
// RESULT TYPES
// ============================================================================

pub type CachexStartResult {
  CachexStartOk(pid: Pid)
  CachexStartError(reason: String)
}

// Generic get result for any type
pub type CachexGetResult(value_type) {
  CachexGetOk(value: Option(value_type))
  CachexGetError(reason: String)
}

// Generic put result
pub type CachexPutResult {
  CachexPutOk(result: Bool)
  CachexPutError(reason: String)
}

// ============================================================================
// FFI BINDINGS
// ============================================================================

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "start_link")
fn start_link_ffi(name: a, opts: List(b)) -> CachexStartResult

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "get")
fn get_ffi(cache: a, key: String) -> CachexGetResult(value_type)

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "put")
fn put_ffi(cache: a, key: String, value: value_type) -> CachexPutResult

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "put_with_ttl")
fn put_with_ttl_ffi(
  cache: a,
  key: String,
  value: value_type,
  ttl_ms: Int,
) -> CachexPutResult

pub type CachexExistsResult {
  CachexExistsOk(exists: Bool)
  CachexExistsError(reason: String)
}

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "exists?")
fn exists_ffi(cache: a, key: String) -> CachexExistsResult

pub type CachexDeleteResult {
  CachexDeleteOk(result: Bool)
  CachexDeleteError(reason: String)
}

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "delete")
fn delete_ffi(cache: a, key: String) -> CachexDeleteResult

// Fetch result type - wraps the result from the fallback
pub type CachexFetchResult(value_type) {
  CachexFetchOk(value: Result(value_type, String))
  CachexFetchError(reason: String)
}

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "fetch")
fn fetch_ffi(
  cache: a,
  key: String,
  module: String,
  function: String,
  args: List(b),
  ttl_ms: Int,
) -> CachexFetchResult(value_type)

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "fetch_with_fn")
fn fetch_with_fn_ffi(
  cache: a,
  key: String,
  fallback: fn() -> Result(value_type, String),
  ttl_ms: Int,
) -> CachexFetchResult(value_type)

// ============================================================================
// PUBLIC API
// ============================================================================

pub fn start_link(name: String, opts: List(a)) -> Result(Pid, String) {
  case start_link_ffi(name, opts) {
    CachexStartOk(pid) -> Ok(pid)
    CachexStartError(reason) -> Error(string.inspect(reason))
  }
}

/// Get a value from cache (phantom typed)
pub fn get(cache: String, key: String) -> Result(Option(value_type), String) {
  case get_ffi(cache, key) {
    CachexGetOk(value) -> Ok(value)
    CachexGetError(reason) -> Error(string.inspect(reason))
  }
}

/// Put a value into cache (phantom typed)
pub fn put(
  cache: String,
  key: String,
  value: value_type,
) -> Result(Bool, String) {
  case put_ffi(cache, key, value) {
    CachexPutOk(result) -> Ok(result)
    CachexPutError(reason) -> Error(string.inspect(reason))
  }
}

/// Put a value into cache with TTL in milliseconds
pub fn put_with_ttl(
  cache: String,
  key: String,
  value: value_type,
  ttl_ms: Int,
) -> Result(Bool, String) {
  case put_with_ttl_ffi(cache, key, value, ttl_ms) {
    CachexPutOk(result) -> Ok(result)
    CachexPutError(reason) -> Error(string.inspect(reason))
  }
}

/// Check if a key exists in cache
pub fn exists(cache: String, key: String) -> Result(Bool, String) {
  case exists_ffi(cache, key) {
    CachexExistsOk(exists) -> Ok(exists)
    CachexExistsError(reason) -> Error(string.inspect(reason))
  }
}

/// Delete a key from cache
pub fn delete(cache: String, key: String) -> Result(Bool, String) {
  case delete_ffi(cache, key) {
    CachexDeleteOk(result) -> Ok(result)
    CachexDeleteError(reason) -> Error(string.inspect(reason))
  }
}

// ============================================================================
// LEGACY BOOL API (for backwards compatibility)
// ============================================================================

pub fn get_bool(cache: String, key: String) -> Result(Option(Bool), String) {
  get(cache, key)
}

/// Fetch a value from cache with automatic coalescing.
/// If the key doesn't exist, calls the fallback (module.function(args)) to compute it.
/// Multiple simultaneous requests for the same key will only execute the fallback ONCE.
///
/// The fallback function must return Result(value, String).
/// On success, the value is cached with the specified TTL.
/// On error, the error is returned but NOT cached.
pub fn fetch(
  cache: String,
  key: String,
  module: String,
  function: String,
  args: List(a),
  ttl_ms: Int,
) -> Result(value_type, String) {
  case fetch_ffi(cache, key, module, function, args, ttl_ms) {
    CachexFetchOk(Ok(value)) -> Ok(value)
    CachexFetchOk(Error(reason)) -> Error(reason)
    CachexFetchError(reason) -> Error(reason)
  }
}

/// Fetch a value from cache with automatic coalescing using a Gleam function.
/// This is the preferred way to use fetch from Gleam code.
///
/// Multiple simultaneous requests for the same key will only execute the fallback ONCE.
/// Other requests wait and share the result (coalescing).
///
/// Example:
///   cachex.fetch_with(
///     "my_cache",
///     "user:123",
///     fn() { expensive_lookup("123") },
///     60_000  // 1 minute TTL
///   )
pub fn fetch_with(
  cache: String,
  key: String,
  fallback: fn() -> Result(value_type, String),
  ttl_ms: Int,
) -> Result(value_type, String) {
  case fetch_with_fn_ffi(cache, key, fallback, ttl_ms) {
    CachexFetchOk(Ok(value)) -> Ok(value)
    CachexFetchOk(Error(reason)) -> Error(reason)
    CachexFetchError(reason) -> Error(reason)
  }
}

pub fn put_bool(cache: String, key: String, value: Bool) -> Result(Bool, String) {
  put(cache, key, value)
}
