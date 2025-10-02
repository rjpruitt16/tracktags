import gleam/erlang/process.{type Pid}
import gleam/option.{type Option}
import gleam/string

pub type CachexStartResult {
  CachexStartOk(pid: Pid)
  CachexStartError(reason: String)
}

pub type CachexGetResult {
  CachexGetOk(value: Option(Bool))
  CachexGetError(reason: String)
}

pub type CachexPutResult {
  CachexPutOk(result: Bool)
  CachexPutError(reason: String)
}

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "start_link")
fn start_link_ffi(name: a, opts: List(b)) -> CachexStartResult

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "get")
fn get_ffi(cache: a, key: String) -> CachexGetResult

@external(erlang, "Elixir.Tracktags.Utils.Cachex", "put")
fn put_ffi(cache: a, key: String, value: Bool) -> CachexPutResult

pub fn start_link(name: String, opts: List(a)) -> Result(Pid, String) {
  case start_link_ffi(name, opts) {
    CachexStartOk(pid) -> Ok(pid)
    CachexStartError(reason) -> Error(string.inspect(reason))
  }
}

pub fn get(cache: String, key: String) -> Result(Option(Bool), String) {
  case get_ffi(cache, key) {
    CachexGetOk(value) -> Ok(value)
    CachexGetError(reason) -> Error(string.inspect(reason))
  }
}

pub fn put(cache: String, key: String, value: Bool) -> Result(Bool, String) {
  case put_ffi(cache, key, value) {
    CachexPutOk(result) -> Ok(result)
    CachexPutError(reason) -> Error(string.inspect(reason))
  }
}
