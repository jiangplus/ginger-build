import ginger/executor
import gleam/string

/// A UTF-8 value must survive the round trip through the local command port
/// unchanged.
///
/// Before the fix, env_ffi handed open_port/2 the UTF-8 *bytes* as a character
/// list. open_port encodes `args` according to file:native_name_encoding()
/// (utf8 on macOS and modern Linux), so every byte was re-encoded as a
/// codepoint and "深" (E6 B7 B1) came back as C3 A6 C2 B7 C2 B1.
///
/// This is not a theoretical concern: it is how an Aliyun SMS 签名 reached a
/// production container double-encoded, where every send failed with
/// SMS_SIGNATURE_ILLEGAL and nothing in the deploy output hinted that ginger
/// had altered the value.
pub fn local_command_preserves_non_ascii_test() {
  let assert Ok(out) = executor.run_local_string("printf '深圳市岑赫科技'")
  assert out == "深圳市岑赫科技"
}

/// The byte length is asserted separately because the double-encoding failure
/// is invisible to a careless eye: the mangled form is still a valid string and
/// still prints, it is just twice the size and means nothing to the receiver.
pub fn local_command_does_not_double_encode_test() {
  let assert Ok(out) = executor.run_local_string("printf '深圳'")
  // Two CJK characters: 6 bytes as UTF-8, 12 if each byte were re-encoded.
  assert string.byte_size(out) == 6
  assert string.length(out) == 2
}

/// Non-ASCII must survive an environment variable too, which is the shape the
/// real bug took — a secret read from a dotenv file and passed through to a
/// container.
pub fn env_assignment_preserves_non_ascii_test() {
  let assert Ok(out) =
    executor.run_local_string("SIGN='深圳市岑赫科技'; printf '%s' \"$SIGN\"")
  assert out == "深圳市岑赫科技"
}
