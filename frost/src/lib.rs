//! OrangeBubbles FROST FFI (ADR 0008 frost-v1).
//!
//! Swift-callable threshold Schnorr for Taproot vaults. This layer is
//! stateless per call and JSON-serializes FROST's types across the FFI —
//! the Swift side orchestrates the multi-round ceremony over iMessage
//! cards, so no participant's secret ever leaves its own device.
//!
//! NOT SHIPPED to real funds until ADR 0008 §8 gate passes; signet only.

use frost_secp256k1_tr as frost;
use rand::rngs::OsRng;
use std::collections::BTreeMap;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FrostError {
    #[error("frost: {0}")]
    Frost(String),
    #[error("decode: {0}")]
    Decode(String),
}
impl From<frost::Error> for FrostError {
    fn from(e: frost::Error) -> Self { FrostError::Frost(e.to_string()) }
}

fn je<T: serde::Serialize>(v: &T) -> String { serde_json::to_string(v).unwrap() }
fn jd<T: serde::de::DeserializeOwned>(s: &str) -> Result<T, FrostError> {
    serde_json::from_str(s).map_err(|e| FrostError::Decode(e.to_string()))
}

// ---- Distributed Key Generation (replaces the trusted dealer) ----

/// DKG round 1: a participant produces its public package (broadcast to
/// all) and a secret package (kept locally, opaque blob).
#[derive(uniffi::Record)]
pub struct DkgRound1 {
    pub secret_package: String,   // keep private on this device
    pub public_package: String,   // broadcast to peers
}

#[uniffi::export]
pub fn dkg_part1(participant_index: u16, max_signers: u16, min_signers: u16) -> Result<DkgRound1, FrostError> {
    let id = frost::Identifier::try_from(participant_index)?;
    let (secret, public) = frost::keys::dkg::part1(id, max_signers, min_signers, OsRng)?;
    Ok(DkgRound1 { secret_package: je(&secret), public_package: je(&public) })
}

/// DKG round 2: consume everyone else's round-1 public packages, emit a
/// per-recipient secret package (each encrypted to that peer by Swift)
/// plus this participant's round-2 secret package.
#[derive(uniffi::Record)]
pub struct DkgRound2 {
    pub secret_package: String,
    /// participant_index -> secret package to send to that peer
    pub outgoing: std::collections::HashMap<u16, String>,
}

#[uniffi::export]
pub fn dkg_part2(round1_secret: String, round1_public_by_index: std::collections::HashMap<u16, String>, max_signers: u16) -> Result<DkgRound2, FrostError> {
    let secret: frost::keys::dkg::round1::SecretPackage = jd(&round1_secret)?;
    let mut received = BTreeMap::new();
    for (idx, pkg) in round1_public_by_index {
        received.insert(frost::Identifier::try_from(idx)?, jd(&pkg)?);
    }
    let (r2_secret, r2_out) = frost::keys::dkg::part2(secret, &received)?;
    let mut outgoing = std::collections::HashMap::new();
    for (id, pkg) in r2_out {
        outgoing.insert(index_of(&id, max_signers)?, je(&pkg));
    }
    Ok(DkgRound2 { secret_package: je(&r2_secret), outgoing })
}

/// DKG round 3: finalize into this participant's key package + the shared
/// public key package (the vault's aggregate key).
#[derive(uniffi::Record)]
pub struct DkgResult {
    pub key_package: String,        // this device's signing key (private)
    pub public_key_package: String, // shared; defines the vault key
    pub xonly_pubkey_hex: String,   // the 32-byte taproot output key
}

#[uniffi::export]
pub fn dkg_part3(
    round2_secret: String,
    round1_public_by_index: std::collections::HashMap<u16, String>,
    round2_secret_by_index: std::collections::HashMap<u16, String>,
) -> Result<DkgResult, FrostError> {
    let secret: frost::keys::dkg::round2::SecretPackage = jd(&round2_secret)?;
    let mut r1 = BTreeMap::new();
    for (idx, pkg) in round1_public_by_index { r1.insert(frost::Identifier::try_from(idx)?, jd(&pkg)?); }
    let mut r2 = BTreeMap::new();
    for (idx, pkg) in round2_secret_by_index { r2.insert(frost::Identifier::try_from(idx)?, jd(&pkg)?); }
    let (key_package, pubkeys) = frost::keys::dkg::part3(&secret, &r1, &r2)?;
    Ok(DkgResult {
        key_package: je(&key_package),
        public_key_package: je(&pubkeys),
        xonly_pubkey_hex: xonly_hex(&pubkeys),
    })
}

// ---- Signing (two rounds) ----

#[derive(uniffi::Record)]
pub struct SigningCommitment {
    pub nonces: String,       // SECRET, keep on device — never reuse
    pub commitments: String,  // broadcast
}

/// Round 1: commit fresh nonces for one signing session. The `nonces`
/// blob MUST be used exactly once (Swift persists it bound to the
/// session id and refuses reuse).
#[uniffi::export]
pub fn sign_commit(key_package: String) -> Result<SigningCommitment, FrostError> {
    let kp: frost::keys::KeyPackage = jd(&key_package)?;
    let (nonces, commitments) = frost::round1::commit(kp.signing_share(), &mut OsRng);
    Ok(SigningCommitment { nonces: je(&nonces), commitments: je(&commitments) })
}

/// Round 2: produce this participant's partial signature over `message`
/// (a 32-byte taproot sighash, hex) given all signers' commitments.
#[uniffi::export]
pub fn sign_partial(
    key_package: String,
    nonces: String,
    message_hex: String,
    commitments_by_index: std::collections::HashMap<u16, String>,
) -> Result<String, FrostError> {
    let kp: frost::keys::KeyPackage = jd(&key_package)?;
    let nonces: frost::round1::SigningNonces = jd(&nonces)?;
    let msg = hex::decode(&message_hex).map_err(|e| FrostError::Decode(e.to_string()))?;
    let mut commitments = BTreeMap::new();
    for (idx, c) in commitments_by_index { commitments.insert(frost::Identifier::try_from(idx)?, jd(&c)?); }
    let pkg = frost::SigningPackage::new(commitments, &msg);
    let share = frost::round2::sign(&pkg, &nonces, &kp)?;
    Ok(je(&share))
}

/// Aggregate partials into the final 64-byte BIP340 Schnorr signature
/// (hex) for the Taproot keypath witness.
#[uniffi::export]
pub fn sign_aggregate(
    public_key_package: String,
    message_hex: String,
    commitments_by_index: std::collections::HashMap<u16, String>,
    shares_by_index: std::collections::HashMap<u16, String>,
) -> Result<String, FrostError> {
    let pubkeys: frost::keys::PublicKeyPackage = jd(&public_key_package)?;
    let msg = hex::decode(&message_hex).map_err(|e| FrostError::Decode(e.to_string()))?;
    let mut commitments = BTreeMap::new();
    for (idx, c) in commitments_by_index { commitments.insert(frost::Identifier::try_from(idx)?, jd(&c)?); }
    let mut shares = BTreeMap::new();
    for (idx, s) in shares_by_index { shares.insert(frost::Identifier::try_from(idx)?, jd(&s)?); }
    let pkg = frost::SigningPackage::new(commitments, &msg);
    let sig = frost::aggregate(&pkg, &shares, &pubkeys)?;
    let bytes = sig.serialize().map_err(FrostError::from)?;
    Ok(hex::encode(&bytes[bytes.len() - 64..]))
}

/// The vault's x-only Taproot key (hex) from the shared public package.
#[uniffi::export]
pub fn vault_xonly_hex(public_key_package: String) -> Result<String, FrostError> {
    let pubkeys: frost::keys::PublicKeyPackage = jd(&public_key_package)?;
    Ok(xonly_hex(&pubkeys))
}

fn xonly_hex(pubkeys: &frost::keys::PublicKeyPackage) -> String {
    let vk = pubkeys.verifying_key().serialize().unwrap();
    hex::encode(&vk[vk.len() - 32..])
}
/// Recover a Default identifier's 1..=n index by matching (serialization
/// endianness is an internal detail we refuse to depend on).
fn index_of(id: &frost::Identifier, max_signers: u16) -> Result<u16, FrostError> {
    for i in 1..=max_signers {
        if &frost::Identifier::try_from(i)? == id { return Ok(i); }
    }
    Err(FrostError::Frost("identifier not in 1..=max_signers".into()))
}

// ---- Transaction layer: build sighashes / finalize (ported from the
//      proven tx PoC). Keeps delicate bitcoin-tx construction in Rust. ----

use bitcoin::hashes::Hash as _;
use bitcoin::sighash::{Prevouts, SighashCache};
use bitcoin::{
    absolute, transaction, Address, Amount, OutPoint, ScriptBuf, Sequence, TapSighashType,
    Transaction, TxIn, TxOut, Witness, XOnlyPublicKey,
};
use std::str::FromStr;

fn net(s: &str) -> Result<bitcoin::Network, FrostError> {
    match s {
        "bitcoin" => Ok(bitcoin::Network::Bitcoin),
        "signet" => Ok(bitcoin::Network::Signet),
        "testnet" => Ok(bitcoin::Network::Testnet),
        "regtest" => Ok(bitcoin::Network::Regtest),
        _ => Err(FrostError::Decode(format!("unknown network {s}"))),
    }
}

fn vault_p2tr(xonly_hex: &str, network: bitcoin::Network) -> Result<Address, FrostError> {
    let bytes = hex::decode(xonly_hex).map_err(|e| FrostError::Decode(e.to_string()))?;
    let xonly = XOnlyPublicKey::from_slice(&bytes).map_err(|e| FrostError::Decode(e.to_string()))?;
    // FROST-tr applies the taproot tweak internally: the aggregate key IS
    // the output key (no script tree).
    Ok(Address::p2tr_tweaked(
        bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(xonly),
        network,
    ))
}

/// The vault's deposit/receive address (p2tr) for a given aggregate key.
#[uniffi::export]
pub fn frost_vault_address(xonly_hex: String, network: String) -> Result<String, FrostError> {
    Ok(vault_p2tr(&xonly_hex, net(&network)?)?.to_string())
}

#[derive(uniffi::Record)]
pub struct FrostUtxo {
    pub txid: String,
    pub vout: u32,
    pub value_sats: u64,
}

#[derive(uniffi::Record)]
pub struct FrostSpendPlan {
    /// Serialized unsigned transaction (hex), witnesses empty.
    pub unsigned_tx_hex: String,
    /// One taproot keypath sighash (hex) per input, in input order.
    pub sighashes_hex: Vec<String>,
}

/// Builds the unsigned sweep/spend transaction and its per-input keypath
/// sighashes. Sends `amount_sats` to `dest` (0 == sweep all minus fee).
#[uniffi::export]
pub fn frost_build_spend(
    xonly_hex: String,
    utxos: Vec<FrostUtxo>,
    dest_address: String,
    amount_sats: u64,
    fee_sats: u64,
    network: String,
) -> Result<FrostSpendPlan, FrostError> {
    let network = net(&network)?;
    let vault = vault_p2tr(&xonly_hex, network)?;
    let dest = Address::from_str(&dest_address)
        .map_err(|e| FrostError::Decode(e.to_string()))?
        .require_network(network)
        .map_err(|e| FrostError::Decode(e.to_string()))?;
    if utxos.is_empty() {
        return Err(FrostError::Frost("no UTXOs to spend".into()));
    }
    let total: u64 = utxos.iter().map(|u| u.value_sats).sum();
    let sweep = amount_sats == 0;
    let send = if sweep { total.saturating_sub(fee_sats) } else { amount_sats };
    if send == 0 || send + fee_sats > total {
        return Err(FrostError::Frost("insufficient funds for amount + fee".into()));
    }

    let input: Vec<TxIn> = utxos
        .iter()
        .map(|u| Ok(TxIn {
            previous_output: OutPoint {
                txid: u.txid.parse().map_err(|_| FrostError::Decode("bad txid".into()))?,
                vout: u.vout,
            },
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::new(),
        }))
        .collect::<Result<_, FrostError>>()?;
    let prevouts: Vec<TxOut> = utxos
        .iter()
        .map(|u| TxOut { value: Amount::from_sat(u.value_sats), script_pubkey: vault.script_pubkey() })
        .collect();

    let mut output = vec![TxOut { value: Amount::from_sat(send), script_pubkey: dest.script_pubkey() }];
    if !sweep {
        let change = total - send - fee_sats;
        if change > 546 {
            output.push(TxOut { value: Amount::from_sat(change), script_pubkey: vault.script_pubkey() });
        }
    }

    let tx = Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input,
        output,
    };

    let mut cache = SighashCache::new(&tx);
    let mut sighashes = Vec::new();
    for i in 0..tx.input.len() {
        let sh = cache
            .taproot_key_spend_signature_hash(i, &Prevouts::All(&prevouts), TapSighashType::Default)
            .map_err(|e| FrostError::Frost(e.to_string()))?;
        sighashes.push(hex::encode(sh.to_raw_hash().to_byte_array()));
    }

    Ok(FrostSpendPlan {
        unsigned_tx_hex: bitcoin::consensus::encode::serialize_hex(&tx),
        sighashes_hex: sighashes,
    })
}

/// Injects one 64-byte Schnorr signature (hex) per input into the unsigned
/// tx and returns the broadcast-ready raw transaction (hex).
#[uniffi::export]
pub fn frost_finalize_spend(
    unsigned_tx_hex: String,
    signatures_hex: Vec<String>,
) -> Result<String, FrostError> {
    let raw = hex::decode(&unsigned_tx_hex).map_err(|e| FrostError::Decode(e.to_string()))?;
    let mut tx: Transaction = bitcoin::consensus::encode::deserialize(&raw)
        .map_err(|e| FrostError::Decode(e.to_string()))?;
    if signatures_hex.len() != tx.input.len() {
        return Err(FrostError::Frost("signature count != input count".into()));
    }
    for (i, sig_hex) in signatures_hex.iter().enumerate() {
        let sig = hex::decode(sig_hex).map_err(|e| FrostError::Decode(e.to_string()))?;
        if sig.len() != 64 {
            return Err(FrostError::Frost("signature must be 64 bytes".into()));
        }
        let mut w = Witness::new();
        w.push(sig);
        tx.input[i].witness = w;
    }
    Ok(bitcoin::consensus::encode::serialize_hex(&tx))
}
