//! FROST research track — REAL signet Taproot keypath spend.
//! ADR 0008 §8: signet-only, dealer keygen (DKG later), never real funds.
//!
//! Subcommands:
//!   address        derive the vault Taproot address from a fixed key
//!   spend <dest>   sweep the vault UTXO(s) to <dest>, FROST-signed, broadcast
//!
//! The 2-of-3 FROST key material is regenerated deterministically from a
//! fixed dealer seed so `address` and `spend` agree across runs — a
//! research shortcut only (a real vault never lets one machine hold the
//! shares; DKG replaces this).

use bitcoin::hashes::Hash;
use bitcoin::sighash::{Prevouts, SighashCache};
use bitcoin::{
    absolute, transaction, Address, Amount, OutPoint, ScriptBuf, Sequence, TapSighashType,
    Transaction, TxIn, TxOut, Witness, XOnlyPublicKey,
};
use frost_secp256k1_tr as frost;
use rand::SeedableRng;
use std::collections::BTreeMap;
use std::str::FromStr;

const ESPLORA: &str = "https://mempool.space/signet/api";

fn keygen() -> (
    BTreeMap<frost::Identifier, frost::keys::KeyPackage>,
    frost::keys::PublicKeyPackage,
) {
    // Fixed dealer RNG → stable key across runs (RESEARCH ONLY).
    let mut rng = rand::rngs::StdRng::seed_from_u64(0x4f52414e47450001u64);
    let (shares, pubkeys) =
        frost::keys::generate_with_dealer(3, 2, frost::keys::IdentifierList::Default, &mut rng)
            .expect("keygen");
    let kps = shares
        .into_iter()
        .map(|(id, ss)| (id, frost::keys::KeyPackage::try_from(ss).unwrap()))
        .collect();
    (kps, pubkeys)
}

fn vault_xonly(pubkeys: &frost::keys::PublicKeyPackage) -> XOnlyPublicKey {
    let vk = pubkeys.verifying_key().serialize().unwrap();
    XOnlyPublicKey::from_slice(&vk[vk.len() - 32..]).unwrap()
}

fn vault_address(pubkeys: &frost::keys::PublicKeyPackage) -> Address {
    // FROST-tr already applies the taproot tweak internally, so the
    // aggregate key IS the output key: p2tr with no script tree.
    let internal = vault_xonly(pubkeys);
    Address::p2tr_tweaked(
        bitcoin::key::TweakedPublicKey::dangerous_assume_tweaked(internal),
        bitcoin::Network::Signet,
    )
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let (key_packages, pubkeys) = keygen();
    let address = vault_address(&pubkeys);

    match args.get(1).map(String::as_str) {
        Some("address") => {
            println!("{address}");
        }
        Some("spend") => {
            let dest = Address::from_str(&args[2])?.require_network(bitcoin::Network::Signet)?;
            spend(&key_packages, &pubkeys, &address, &dest)?;
        }
        _ => println!("usage: tx address | tx spend <dest>"),
    }
    Ok(())
}

#[derive(serde::Deserialize)]
struct Utxo {
    txid: String,
    vout: u32,
    value: u64,
}

fn spend(
    key_packages: &BTreeMap<frost::Identifier, frost::keys::KeyPackage>,
    pubkeys: &frost::keys::PublicKeyPackage,
    vault: &Address,
    dest: &Address,
) -> Result<(), Box<dyn std::error::Error>> {
    let utxos: Vec<Utxo> = ureq::get(&format!("{ESPLORA}/address/{vault}/utxo"))
        .call()?
        .into_json()?;
    if utxos.is_empty() {
        println!("no UTXOs at {vault} yet — fund it first");
        return Ok(());
    }
    let total: u64 = utxos.iter().map(|u| u.value).sum();
    let fee = 300u64;
    let send = total - fee;
    println!("spending {} sats from {} UTXO(s), fee {}", send, utxos.len(), fee);

    let inputs: Vec<TxIn> = utxos
        .iter()
        .map(|u| TxIn {
            previous_output: OutPoint {
                txid: u.txid.parse().unwrap(),
                vout: u.vout,
            },
            script_sig: ScriptBuf::new(),
            sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
            witness: Witness::new(),
        })
        .collect();
    let prevouts: Vec<TxOut> = utxos
        .iter()
        .map(|u| TxOut {
            value: Amount::from_sat(u.value),
            script_pubkey: vault.script_pubkey(),
        })
        .collect();

    let mut tx = Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input: inputs,
        output: vec![TxOut {
            value: Amount::from_sat(send),
            script_pubkey: dest.script_pubkey(),
        }],
    };

    // Sign every input with a fresh FROST ceremony over its sighash.
    let signers: Vec<_> = key_packages.keys().take(2).cloned().collect();
    let mut cache = SighashCache::new(&tx);
    let mut witnesses = Vec::new();
    for i in 0..tx.input.len() {
        let sighash = cache.taproot_key_spend_signature_hash(
            i,
            &Prevouts::All(&prevouts),
            TapSighashType::Default,
        )?;
        let msg = sighash.to_raw_hash().to_byte_array();

        let mut rng = rand::thread_rng();
        let mut nonces = BTreeMap::new();
        let mut commits = BTreeMap::new();
        for id in &signers {
            let (n, c) = frost::round1::commit(key_packages[id].signing_share(), &mut rng);
            nonces.insert(*id, n);
            commits.insert(*id, c);
        }
        let pkg = frost::SigningPackage::new(commits, &msg);
        let mut partials = BTreeMap::new();
        for id in &signers {
            partials.insert(*id, frost::round2::sign(&pkg, &nonces[id], &key_packages[id])?);
        }
        let group_sig = frost::aggregate(&pkg, &partials, pubkeys)?;
        pubkeys.verifying_key().verify(&msg, &group_sig)?;

        let sig_bytes = group_sig.serialize()?;
        let sig64: [u8; 64] = sig_bytes[sig_bytes.len() - 64..].try_into()?;
        let mut w = Witness::new();
        w.push(sig64); // keypath spend: single Schnorr sig
        witnesses.push(w);
    }
    for (i, w) in witnesses.into_iter().enumerate() {
        tx.input[i].witness = w;
    }

    let raw = bitcoin::consensus::encode::serialize_hex(&tx);
    println!("signed tx: {raw}");
    let resp = ureq::post(&format!("{ESPLORA}/tx")).send_string(&raw);
    match resp {
        Ok(r) => println!("BROADCAST TXID: {}", r.into_string()?),
        Err(ureq::Error::Status(code, r)) => {
            println!("broadcast rejected ({code}): {}", r.into_string()?)
        }
        Err(e) => println!("broadcast error: {e}"),
    }
    Ok(())
}
