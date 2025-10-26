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

// ============================================================================
// LEGACY BOOL API (for backwards compatibility)
// ============================================================================

pub fn get_bool(cache: String, key: String) -> Result(Option(Bool), String) {
  get(cache, key)
}

pub fn put_bool(cache: String, key: String, value: Bool) -> Result(Bool, String) {
  put(cache, key, value)
}
