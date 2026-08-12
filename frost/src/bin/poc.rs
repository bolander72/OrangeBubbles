//! FROST research track PoC (ADR 0008 §8 — signet-only, never ships
//! to real users before the readiness gate passes).
//!
//! Proves the core claim end to end on this machine:
//!   1. Dealer-based 2-of-3 FROST key generation (DKG comes later)
//!   2. Two-round threshold signing over a fake sighash
//!   3. The aggregate signature verifies as a STANDARD BIP340 Schnorr
//!      signature under an independent library (rust-secp256k1) —
//!      i.e. it would be a valid Taproot keypath spend.

use frost_secp256k1_tr as frost;
use std::collections::BTreeMap;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut rng = rand::thread_rng();

    // 1. Keygen: 2-of-3, trusted dealer (research only; DKG later).
    let (secret_shares, pubkey_package) = frost::keys::generate_with_dealer(
        3,
        2,
        frost::keys::IdentifierList::Default,
        &mut rng,
    )?;
    let key_packages: BTreeMap<_, _> = secret_shares
        .into_iter()
        .map(|(id, ss)| (id, frost::keys::KeyPackage::try_from(ss).unwrap()))
        .collect();

    // Pretend this is a taproot keypath sighash.
    let message = *b"orangebubbles-frost-poc-sighash!";

    // 2. Round 1: two of the three participants commit nonces.
    let signers: Vec<_> = key_packages.keys().take(2).cloned().collect();
    let mut nonces_map = BTreeMap::new();
    let mut commitments_map = BTreeMap::new();
    for id in &signers {
        let (nonces, commitments) =
            frost::round1::commit(key_packages[id].signing_share(), &mut rng);
        nonces_map.insert(*id, nonces);
        commitments_map.insert(*id, commitments);
    }

    // Round 2: partial signatures.
    let signing_package = frost::SigningPackage::new(commitments_map, &message);
    let mut partials = BTreeMap::new();
    for id in &signers {
        let sig_share =
            frost::round2::sign(&signing_package, &nonces_map[id], &key_packages[id])?;
        partials.insert(*id, sig_share);
    }

    // Aggregate into one signature.
    let group_sig = frost::aggregate(&signing_package, &partials, &pubkey_package)?;
    pubkey_package
        .verifying_key()
        .verify(&message, &group_sig)?;
    println!("frost-internal verify: OK");

    // 3. Independent BIP340 verification via rust-secp256k1.
    let sig_bytes = group_sig.serialize()?;
    let sig64: [u8; 64] = sig_bytes[sig_bytes.len() - 64..].try_into()?;
    let vk_bytes = pubkey_package.verifying_key().serialize()?;
    let xonly_bytes: [u8; 32] = vk_bytes[vk_bytes.len() - 32..].try_into()?;

    let secp = secp256k1::Secp256k1::verification_only();
    let xonly = secp256k1::XOnlyPublicKey::from_slice(&xonly_bytes)?;
    let schnorr_sig = secp256k1::schnorr::Signature::from_slice(&sig64)?;
    let msg = secp256k1::Message::from_digest(message);
    secp.verify_schnorr(&schnorr_sig, &msg, &xonly)?;

    println!("independent BIP340 verify (rust-secp256k1): OK");
    println!("aggregate x-only pubkey: {}", hex::encode(xonly_bytes));
    println!("signature: {}", hex::encode(sig64));
    println!("\n2-of-3 FROST ceremony -> valid Taproot keypath signature ✓");
    Ok(())
}
