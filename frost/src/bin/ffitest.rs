//! Proves the FFI surface end-to-end: 3-party DKG (no dealer) + 2-of-3
//! signing, everything crossing the JSON/HashMap boundary exactly as
//! Swift will call it. Verifies output as standard BIP340.
use obfrost::*;
use std::collections::HashMap;

fn main() {
    let n = 3u16; let k = 2u16;

    // ---- DKG round 1: each participant locally ----
    let r1: Vec<DkgRound1> = (1..=n).map(|i| dkg_part1(i, n, k).unwrap()).collect();
    let r1_public: HashMap<u16, String> =
        (1..=n).map(|i| (i, r1[(i-1) as usize].public_package.clone())).collect();

    // ---- DKG round 2: each consumes others' r1 public pkgs ----
    let mut r2: Vec<DkgRound2> = Vec::new();
    for i in 1..=n {
        let others: HashMap<u16,String> = r1_public.iter()
            .filter(|(idx,_)| **idx != i).map(|(k,v)|(*k,v.clone())).collect();
        r2.push(dkg_part2(r1[(i-1) as usize].secret_package.clone(), others, n).unwrap());
    }

    // ---- DKG round 3: each finalizes ----
    let mut key_packages: HashMap<u16,String> = HashMap::new();
    let mut pubkey_pkg = String::new();
    for i in 1..=n {
        let r1_others: HashMap<u16,String> = r1_public.iter()
            .filter(|(idx,_)| **idx != i).map(|(k,v)|(*k,v.clone())).collect();
        // gather the round-2 secret packages addressed TO participant i
        let r2_to_me: HashMap<u16,String> = (1..=n).filter(|j| *j != i)
            .map(|j| (j, r2[(j-1) as usize].outgoing.get(&i).unwrap().clone())).collect();
        let res = dkg_part3(r2[(i-1) as usize].secret_package.clone(), r1_others, r2_to_me).unwrap();
        key_packages.insert(i, res.key_package);
        pubkey_pkg = res.public_key_package;
    }
    let vault_key = vault_xonly_hex(pubkey_pkg.clone()).unwrap();
    println!("DKG complete — vault x-only key: {vault_key}");

    // ---- Signing: participants 1 and 2 ----
    let signers = [1u16, 2u16];
    let message_hex = hex::encode([7u8; 32]);
    let mut commitments: HashMap<u16,String> = HashMap::new();
    let mut nonces: HashMap<u16,String> = HashMap::new();
    for s in signers {
        let c = sign_commit(key_packages[&s].clone()).unwrap();
        commitments.insert(s, c.commitments);
        nonces.insert(s, c.nonces);
    }
    let mut shares: HashMap<u16,String> = HashMap::new();
    for s in signers {
        let share = sign_partial(key_packages[&s].clone(), nonces[&s].clone(),
            message_hex.clone(), commitments.clone()).unwrap();
        shares.insert(s, share);
    }
    let sig = sign_aggregate(pubkey_pkg, message_hex.clone(), commitments, shares).unwrap();
    println!("aggregate signature: {sig}");

    // ---- Independent BIP340 verify ----
    let secp = secp256k1::Secp256k1::verification_only();
    let xonly = secp256k1::XOnlyPublicKey::from_slice(&hex::decode(&vault_key).unwrap()).unwrap();
    let schnorr = secp256k1::schnorr::Signature::from_slice(&hex::decode(&sig).unwrap()).unwrap();
    let msg = secp256k1::Message::from_digest([7u8;32]);
    secp.verify_schnorr(&schnorr, &msg, &xonly).unwrap();
    println!("\nDKG (no dealer) + 2-of-3 signing over the FFI -> valid BIP340 ✓");
}
