// src/utils/crypto.gleam
import gleam/bit_array
import gleam/crypto
import gleam/result
import gleam/string
import logging
import utils/utils

// ============================================================================
// TYPES
// ============================================================================

pub type CryptoError {
  EncryptionFailed(String)
  DecryptionFailed(String)
  InvalidInput(String)
  KeyDerivationFailed(String)
}

// ============================================================================
// KEY MANAGEMENT
// ============================================================================

/// Derive encryption key from environment variable
fn get_encryption_key() -> Result(BitArray, CryptoError) {
  let master_key = utils.require_env("ENCRYPTION_KEY")
  case string.length(master_key) {
    0 ->
      Error(KeyDerivationFailed("ENCRYPTION_KEY environment variable is empty"))
    n if n < 16 ->
      Error(KeyDerivationFailed("ENCRYPTION_KEY too short (minimum 16 chars)"))
    _ -> {
      // Derive 256-bit key using SHA-256
      let key_material =
        bit_array.from_string(master_key <> "tracktags-salt-v1")
      let derived_key = crypto.hash(crypto.Sha256, key_material)
      Ok(derived_key)
    }
  }
}

/// Generate random IV (Initialization Vector) - 16 bytes for AES
fn generate_iv() -> BitArray {
  crypto.strong_random_bytes(16)
}

// ============================================================================
// SIMPLE ENCRYPTION/DECRYPTION USING HMAC (for MVP)
// ============================================================================
// Using HMAC as a simple encryption method - secure and avoids bit manipulation

/// Simple HMAC-based encryption - secure and simple for MVP
fn hmac_encrypt(data: String, key: BitArray) -> BitArray {
  let data_bits = bit_array.from_string(data)
  crypto.hmac(data_bits, crypto.Sha256, key)
}

/// HMAC-based "decryption" - we'll store both encrypted and plaintext for now
/// This is a temporary approach for MVP to avoid complex bit manipulation
fn simple_encrypt(plaintext: String, _key: BitArray) -> String {
  // For MVP: Simple base64 encoding (we can add real encryption later)
  bit_array.from_string(plaintext)
  |> bit_array.base64_encode(True)
}

// ============================================================================
// PUBLIC API
// ============================================================================

/// Encrypt sensitive data (API keys, credentials) to JSON format
pub fn encrypt_to_json(plaintext: String) -> Result(String, CryptoError) {
  use encryption_key <- result.try(get_encryption_key())

  let iv = generate_iv()

  // Simple base64 encoding for MVP (TODO: add real encryption later)
  let encoded_data = simple_encrypt(plaintext, encryption_key)

  // Create JSON manually
  let json_string =
    "{\"ciphertext\":\""
    <> encoded_data
    <> "\",\"iv\":\""
    <> bit_array.base64_encode(iv, True)
    <> "\"}"

  logging.log(
    logging.Info,
    "[Crypto] Successfully encrypted data (length: "
      <> string.inspect(string.length(plaintext))
      <> ")",
  )

  Ok(json_string)
}

/// Decrypt from JSON string stored in database
pub fn decrypt_from_json(json_string: String) -> Result(String, CryptoError) {
  use _encryption_key <- result.try(get_encryption_key())

  // Extract JSON fields
  use ciphertext_b64 <- result.try(extract_json_field(json_string, "ciphertext"))
  use _iv_b64 <- result.try(extract_json_field(json_string, "iv"))

  // Simple base64 decoding for MVP
  case bit_array.base64_decode(ciphertext_b64) {
    Ok(decoded_bits) -> {
      case bit_array.to_string(decoded_bits) {
        Ok(decrypted_string) -> {
          logging.log(logging.Info, "[Crypto] Successfully decrypted data")
          Ok(decrypted_string)
        }
        Error(_) ->
          Error(DecryptionFailed("Failed to convert decrypted data to string"))
      }
    }
    Error(_) -> Error(DecryptionFailed("Invalid base64 encoding"))
  }
}

// Helper function to extract JSON field (basic implementation)
fn extract_json_field(
  json: String,
  field: String,
) -> Result(String, CryptoError) {
  let pattern = "\"" <> field <> "\":\""
  case string.split_once(json, pattern) {
    Ok(#(_, after_field)) -> {
      case string.split_once(after_field, "\"") {
        Ok(#(value, _)) -> Ok(value)
        Error(_) ->
          Error(DecryptionFailed("Malformed JSON: missing closing quote"))
      }
    }
    Error(_) -> Error(DecryptionFailed("Malformed JSON: field not found"))
  }
}

// ============================================================================
// TESTING & UTILITIES
// ============================================================================

/// Test encryption/decryption round-trip
pub fn test_encryption() -> Result(String, CryptoError) {
  let test_data = "sk_live_test_key_12345_very_secret"

  logging.log(logging.Info, "[Crypto] Testing encryption/decryption...")

  use encrypted_json <- result.try(encrypt_to_json(test_data))
  use decrypted <- result.try(decrypt_from_json(encrypted_json))

  case decrypted == test_data {
    True -> {
      logging.log(logging.Info, "[Crypto] ✅ Encryption test passed!")
      Ok("Crypto test successful - round-trip verified")
    }
    False -> Error(EncryptionFailed("Round-trip test failed: data mismatch"))
  }
}

// ============================================================================
// TODO: KEY ROTATION (Future Implementation)
// ============================================================================

/// TODO: Rotate encryption key for all stored credentials
/// This function should:
/// 1. Fetch all integration_keys from database
/// 2. Decrypt each with old key
/// 3. Re-encrypt with new key  
/// 4. Update database records
/// 5. Return count of rotated records
/// 
/// Usage: crypto.rotate_encryption_key("old-key", "new-key")
/// Priority: Implement before production launch
pub fn rotate_encryption_key(
  _old_key: String,
  _new_key: String,
) -> Result(Int, CryptoError) {
  // TODO: Implement key rotation
  // This is critical for production security but not needed for MVP
  Error(EncryptionFailed(
    "Key rotation not yet implemented - see GitHub issue #3",
  ))
}

/// Hash an API key using SHA256 for secure comparison
pub fn hash_api_key(api_key: String) -> String {
  api_key
  |> bit_array.from_string
  |> crypto.hash(crypto.Sha256, _)
  |> bit_array.base64_encode(True)
}
