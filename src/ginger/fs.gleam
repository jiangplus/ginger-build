/// Read a local file's contents. Thin wrapper over the env FFI.
@external(erlang, "env_ffi", "read_file")
pub fn read_file(path: String) -> Result(String, String)
