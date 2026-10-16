import CryptoKit
import Foundation
import P256K

// BIP352 silent payments — the SENDING half.
//
// A silent payment address (`sp1…` / `tsp1…`) is a static pair of public keys
// (B_scan, B_spend). Paying one means deriving a one-time taproot output from
// our inputs' private keys and the recipient's keys, so the recipient's
// address never appears on chain. Everything here is the arithmetic in the
// BIP; nothing touches the network or the wallet database. The receiving
// half (scanning) needs a tweak index that no public Esplora serves, and is
// deliberately not implemented — see docs/decisions/0010-silent-payments.md.

/// A parsed `sp1…` / `tsp1…` address: scan key and (possibly labelled) spend key.
public struct SilentPaymentAddress: Equatable, Sendable {
    /// Compressed 33-byte B_scan.
    public let scanKey: [UInt8]
    /// Compressed 33-byte B_m (B_spend, or a labelled variant of it).
    public let spendKey: [UInt8]
    /// `sp` on mainnet, `tsp` on every test network.
    public let hrp: String
    public let version: UInt8

    public var isMainnet: Bool { hrp == "sp" }

    public init?(scanKey: [UInt8], spendKey: [UInt8], hrp: String, version: UInt8 = 0) {
        guard scanKey.count == 33, spendKey.count == 33 else { return nil }
        self.scanKey = scanKey
        self.spendKey = spendKey
        self.hrp = hrp
        self.version = version
    }

    /// Parses a silent payment address. Returns nil for anything that is not
    /// one (so callers can fall through to ordinary address parsing).
    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 1023, let (hrp, data) = Bech32m.decode(s), hrp == "sp" || hrp == "tsp" else { return nil }
        guard let versionChar = data.first else { return nil }
        let version = versionChar
        // Version 31 is reserved and must fail; 1–30 are forward-compatible
        // (read the first 66 bytes, ignore the rest); 0 must be exactly 66.
        guard version != 31 else { return nil }
        guard let payload = Bech32m.convertBits(Array(data.dropFirst()), from: 5, to: 8, pad: false) else { return nil }
        if version == 0 { guard payload.count == 66 else { return nil } }
        guard payload.count >= 66 else { return nil }
        guard let parsed = SilentPaymentAddress(
            scanKey: Array(payload[0..<33]), spendKey: Array(payload[33..<66]), hrp: hrp, version: version
        ) else { return nil }
        // Both keys must be valid curve points.
        guard (try? P256K.Signing.PublicKey(dataRepresentation: parsed.scanKey, format: .compressed)) != nil,
              (try? P256K.Signing.PublicKey(dataRepresentation: parsed.spendKey, format: .compressed)) != nil
        else { return nil }
        self = parsed
    }

    public var string: String {
        let payload = Bech32m.convertBits(scanKey + spendKey, from: 8, to: 5, pad: true) ?? []
        return Bech32m.encode(hrp: hrp, data: [version] + payload)
    }

    /// True when the address belongs on the given network family.
    public func matches(network: NetworkKind) -> Bool {
        network == .bitcoin ? isMainnet : !isMainnet
    }
}

/// One input the sender controls, in the form BIP352 needs.
public struct SilentPaymentInput: Equatable, Sendable {
    /// 36-byte outpoint as serialised in a transaction: txid (internal byte
    /// order, i.e. reversed from the display hex) followed by little-endian vout.
    public let outpoint: [UInt8]
    /// 32-byte private key that controls the input.
    public let privateKey: [UInt8]
    /// Taproot inputs contribute their *output* key, whose parity may require
    /// negating the private key; other eligible types do not.
    public let isTaproot: Bool

    public init(outpoint: [UInt8], privateKey: [UInt8], isTaproot: Bool) {
        self.outpoint = outpoint
        self.privateKey = privateKey
        self.isTaproot = isTaproot
    }

    public init(txidHex: String, vout: UInt32, privateKey: [UInt8], isTaproot: Bool) {
        let txid = Array(Hex.bytes(txidHex).reversed())
        let voutLE = withUnsafeBytes(of: vout.littleEndian) { Array($0) }
        self.init(outpoint: txid + voutLE, privateKey: privateKey, isTaproot: isTaproot)
    }
}

public enum SilentPaymentError: LocalizedError, Equatable {
    case noEligibleInputs
    case inputKeysSumToZero
    case tooManyRecipientsForOneScanKey
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .noEligibleInputs: return "None of the coins being spent can fund a silent payment."
        case .inputKeysSumToZero: return "These coins can't be combined for a silent payment; try a different amount."
        case .tooManyRecipientsForOneScanKey: return "Too many payments to the same silent payment address in one transaction."
        case .invalidKey: return "Invalid key material."
        }
    }
}

public enum SilentPaymentSender {
    /// A derived output: the x-only key for `OP_1 <key>`, and which recipient
    /// (by index into the `recipients` argument) it pays.
    public struct Output: Equatable, Sendable {
        public let recipientIndex: Int
        public let xOnlyKey: [UInt8]
        /// `OP_1 OP_PUSHBYTES_32 <x-only key>`
        public var scriptPubkey: [UInt8] { [0x51, 0x20] + xOnlyKey }
    }

    /// BIP352 sending, straight from the spec. One output per recipient
    /// entry; paying the same address twice gives two distinct outputs.
    ///
    /// `inputs` are the eligible inputs the sender holds keys for.
    /// `transactionOutpoints` are ALL the transaction's input outpoints
    /// (36 bytes each): the BIP takes the lexicographically smallest
    /// outpoint over every input, eligible or not. Defaults to the eligible
    /// inputs' outpoints, which is exact when every input is eligible — as
    /// it is for this wallet's own coins.
    public static func outputs(
        inputs: [SilentPaymentInput],
        recipients: [SilentPaymentAddress],
        transactionOutpoints: [[UInt8]]? = nil
    ) throws -> [Output] {
        guard !inputs.isEmpty else { throw SilentPaymentError.noEligibleInputs }
        guard !recipients.isEmpty else { return [] }

        // a = Σ a_i, negating taproot keys whose public key has odd Y.
        var sum = Scalar.zero
        for input in inputs {
            guard input.privateKey.count == 32, let scalar = Scalar(bytes: input.privateKey) else {
                throw SilentPaymentError.invalidKey
            }
            var a = scalar
            if input.isTaproot {
                let pub = try P256K.Signing.PrivateKey(dataRepresentation: input.privateKey).publicKey
                if pub.dataRepresentation.first == 0x03 { a = a.negated() }
            }
            sum = sum.adding(a)
        }
        guard !sum.isZero else { throw SilentPaymentError.inputKeysSumToZero }
        let aKey = try P256K.Signing.PrivateKey(dataRepresentation: sum.bytes)
        let aPub = Array(aKey.publicKey.dataRepresentation) // compressed A

        // input_hash = hash_{BIP0352/Inputs}(outpoint_L || A), outpoint_L the
        // lexicographically smallest outpoint (byte-wise, as serialised).
        let allOutpoints = transactionOutpoints ?? inputs.map(\.outpoint)
        let smallest = allOutpoints.min { $0.lexicographicallyPrecedes($1) }!
        let inputHash = TaggedHash.bip352Inputs(smallest + aPub)
        guard let inputHashScalar = Scalar(bytes: inputHash), !inputHashScalar.isZero else {
            throw SilentPaymentError.invalidKey
        }

        // ecdh = input_hash · a · B_scan, one per distinct scan key.
        let tweakedA = try aKey.multiply(inputHash)
        let ecdhKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: tweakedA.dataRepresentation)

        var outputs: [Output] = []
        var byScanKey: [[UInt8]: [Int]] = [:]
        var order: [[UInt8]] = []
        for (index, recipient) in recipients.enumerated() {
            if byScanKey[recipient.scanKey] == nil { order.append(recipient.scanKey) }
            byScanKey[recipient.scanKey, default: []].append(index)
        }
        for scanKey in order {
            let group = byScanKey[scanKey]!
            guard group.count <= 2323 else { throw SilentPaymentError.tooManyRecipientsForOneScanKey }
            let bScan = try P256K.KeyAgreement.PublicKey(dataRepresentation: scanKey, format: .compressed)
            let shared = Array(ecdhKey.sharedSecretFromKeyAgreement(with: bScan, format: .compressed).bytes)
            var k: UInt32 = 0
            for index in group {
                let tk = TaggedHash.bip352SharedSecret(shared + k.bigEndianBytes)
                guard let tkScalar = Scalar(bytes: tk), !tkScalar.isZero else { throw SilentPaymentError.invalidKey }
                let bm = try P256K.Signing.PublicKey(dataRepresentation: recipients[index].spendKey, format: .compressed)
                let pmk = try bm.add(tk)
                outputs.append(Output(recipientIndex: index, xOnlyKey: Array(pmk.xonly.bytes)))
                k += 1
            }
        }
        return outputs.sorted { $0.recipientIndex < $1.recipientIndex }
    }

    /// Which of the sender's inputs count for BIP352, and whether each is a
    /// taproot spend. Mirrors the BIP's eligibility rules so wallets holding
    /// mixed coins (or test vectors) can filter before calling `outputs`.
    public static func classify(prevoutScriptPubkey spk: [UInt8], scriptSig: [UInt8], witness: [[UInt8]]) -> (eligible: Bool, isTaproot: Bool, publicKey: [UInt8]?) {
        // P2TR: OP_1 <32>. Skip when the control block reveals the NUMS
        // internal key (a script-path spend with provably no key path).
        if spk.count == 34, spk[0] == 0x51, spk[1] == 0x20 {
            // An annex (last item starting 0x50) sits after the control block.
            var items = witness
            if items.count >= 2, items.last?.first == 0x50 { items.removeLast() }
            if items.count > 1, let control = items.last, control.count >= 33 {
                let internalKey = Array(control[1..<33])
                if internalKey == Hex.bytes("50929b74c1a04954b78b4b6035e97a5e078a5a0f28ec96d547bfee9ace803ac0") {
                    return (false, true, nil)
                }
            }
            return (true, true, Array(spk[2..<34]))
        }
        // P2WPKH: OP_0 <20>, key is the second witness item, must be compressed.
        if spk.count == 22, spk[0] == 0x00, spk[1] == 0x14 {
            guard witness.count == 2, witness[1].count == 33 else { return (false, false, nil) }
            return (true, false, witness[1])
        }
        // P2SH-P2WPKH: scriptSig is exactly a push of 0014<20>.
        if spk.count == 23, spk[0] == 0xa9, spk[1] == 0x14, spk[22] == 0x87 {
            guard scriptSig.count == 23, scriptSig[0] == 0x16, scriptSig[1] == 0x00, scriptSig[2] == 0x14,
                  witness.count == 2, witness[1].count == 33 else { return (false, false, nil) }
            return (true, false, witness[1])
        }
        // P2PKH: the key is the last push in scriptSig; must be compressed and
        // must hash to the script's pubkey hash (scriptSigs can be malleated).
        if spk.count == 25, spk[0] == 0x76, spk[1] == 0xa9, spk[2] == 0x14 {
            let expectedHash = Array(spk[3..<23])
            // scriptSigs can be malleated (extra ops before or after), so
            // search every 33-byte window from the end for the key that
            // hashes to the script's pubkey hash. An uncompressed key is
            // not eligible, so a 65-byte match is not looked for.
            if scriptSig.count >= 33 {
                for end in stride(from: scriptSig.count, through: 33, by: -1) {
                    let candidate = Array(scriptSig[(end - 33)..<end])
                    guard candidate[0] == 0x02 || candidate[0] == 0x03 else { continue }
                    if Hash160.hash(candidate) == expectedHash { return (true, false, candidate) }
                }
            }
            return (false, false, nil)
        }
        return (false, false, nil)
    }
}

// MARK: - Helpers

enum TaggedHash {
    static func tagged(_ tag: String, _ data: [UInt8]) -> [UInt8] {
        let tagHash = Array(SHA256.hash(data: Data(tag.utf8)))
        return Array(SHA256.hash(data: Data(tagHash + tagHash + data)))
    }
    static func bip352Inputs(_ data: [UInt8]) -> [UInt8] { tagged("BIP0352/Inputs", data) }
    static func bip352SharedSecret(_ data: [UInt8]) -> [UInt8] { tagged("BIP0352/SharedSecret", data) }
    static func bip352Label(_ data: [UInt8]) -> [UInt8] { tagged("BIP0352/Label", data) }
}

enum Hash160 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        let sha = Array(SHA256.hash(data: Data(data)))
        return RIPEMD160.hash(sha)
    }
}

/// Minimal RIPEMD-160 (CryptoKit does not ship one). Only used to verify
/// P2PKH inputs' public keys.
enum RIPEMD160 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var msg = message
        let bitLength = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        msg += withUnsafeBytes(of: bitLength.littleEndian) { Array($0) }

        let r: [Int] = [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15, 7,4,13,1,10,6,15,3,12,0,9,5,2,14,11,8,
                        3,10,14,4,9,15,8,1,2,7,0,6,13,11,5,12, 1,9,11,10,0,8,12,4,13,3,7,15,14,5,6,2,
                        4,0,5,9,7,12,2,10,14,1,3,8,11,6,15,13]
        let rr: [Int] = [5,14,7,0,9,2,11,4,13,6,15,8,1,10,3,12, 6,11,3,7,0,13,5,10,14,15,8,12,4,9,1,2,
                         15,5,1,3,7,14,6,9,11,8,12,2,10,0,4,13, 8,6,4,1,3,11,15,0,5,12,2,13,9,7,10,14,
                         12,15,10,4,1,5,8,7,6,2,13,14,0,3,9,11]
        let s: [UInt32] = [11,14,15,12,5,8,7,9,11,13,14,15,6,7,9,8, 7,6,8,13,11,9,7,15,7,12,15,9,11,7,13,12,
                           11,13,6,7,14,9,13,15,14,8,13,6,5,12,7,5, 11,12,14,15,14,15,9,8,9,14,5,6,8,6,5,12,
                           9,15,5,11,6,8,13,12,5,12,13,14,11,8,5,6]
        let ss: [UInt32] = [8,9,9,11,13,15,15,5,7,7,8,11,14,14,12,6, 9,13,15,7,12,8,9,11,7,7,12,7,6,15,13,11,
                            9,7,15,11,8,6,6,14,12,13,5,14,13,13,7,5, 15,5,8,11,14,14,6,14,6,9,12,9,12,5,15,8,
                            8,5,12,9,12,5,14,6,8,13,6,5,15,13,11,11]
        let k: [UInt32] = [0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E]
        let kk: [UInt32] = [0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000]

        func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
            switch j / 16 {
            case 0: return x ^ y ^ z
            case 1: return (x & y) | (~x & z)
            case 2: return (x | ~y) ^ z
            case 3: return (x & z) | (y & ~z)
            default: return x ^ (y | ~z)
            }
        }
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = chunk + i * 4
                x[i] = UInt32(msg[b]) | UInt32(msg[b+1]) << 8 | UInt32(msg[b+2]) << 16 | UInt32(msg[b+3]) << 24
            }
            var (al, bl, cl, dl, el) = (h[0], h[1], h[2], h[3], h[4])
            var (ar, br, cr, dr, er) = (h[0], h[1], h[2], h[3], h[4])
            for j in 0..<80 {
                var t = rotl(al &+ f(j, bl, cl, dl) &+ x[r[j]] &+ k[j / 16], s[j]) &+ el
                al = el; el = dl; dl = rotl(cl, 10); cl = bl; bl = t
                t = rotl(ar &+ f(79 - j, br, cr, dr) &+ x[rr[j]] &+ kk[j / 16], ss[j]) &+ er
                ar = er; er = dr; dr = rotl(cr, 10); cr = br; br = t
            }
            let t = h[1] &+ cl &+ dr
            h[1] = h[2] &+ dl &+ er
            h[2] = h[3] &+ el &+ ar
            h[3] = h[4] &+ al &+ br
            h[4] = h[0] &+ bl &+ cr
            h[0] = t
        }
        return h.flatMap { withUnsafeBytes(of: $0.littleEndian) { Array($0) } }
    }
}

/// 256-bit scalar arithmetic modulo the secp256k1 group order, for summing
/// and negating private keys. libsecp256k1 refuses intermediate zero sums,
/// which the BIP explicitly allows, so this is done by hand.
struct Scalar: Equatable {
    /// Big-endian limbs, most significant first.
    private var limbs: [UInt64] // 4 limbs

    static let order: [UInt64] = [0xFFFFFFFF_FFFFFFFF, 0xFFFFFFFF_FFFFFFFE, 0xBAAEDCE6_AF48A03B, 0xBFD25E8C_D0364141]
    static let zero = Scalar(limbs: [0, 0, 0, 0])

    private init(limbs: [UInt64]) { self.limbs = limbs }

    /// nil when the value is not below the group order.
    init?(bytes: [UInt8]) {
        guard bytes.count == 32 else { return nil }
        var limbs = [UInt64](repeating: 0, count: 4)
        for i in 0..<4 {
            for j in 0..<8 { limbs[i] = (limbs[i] << 8) | UInt64(bytes[i * 8 + j]) }
        }
        let s = Scalar(limbs: limbs)
        guard s.lessThan(Scalar(limbs: Scalar.order)) else { return nil }
        self = s
    }

    var bytes: [UInt8] { limbs.flatMap { withUnsafeBytes(of: $0.bigEndian) { Array($0) } } }
    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    private func lessThan(_ other: Scalar) -> Bool {
        for i in 0..<4 where limbs[i] != other.limbs[i] { return limbs[i] < other.limbs[i] }
        return false
    }

    private static func rawAdd(_ a: [UInt64], _ b: [UInt64]) -> (sum: [UInt64], carry: Bool) {
        var out = [UInt64](repeating: 0, count: 4)
        var carry: UInt64 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            out[i] = s2
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return (out, carry != 0)
    }

    private static func rawSub(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var out = [UInt64](repeating: 0, count: 4)
        var borrow: UInt64 = 0
        for i in stride(from: 3, through: 0, by: -1) {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            out[i] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return out
    }

    func adding(_ other: Scalar) -> Scalar {
        let (sum, carry) = Scalar.rawAdd(limbs, other.limbs)
        let s = Scalar(limbs: sum)
        if carry || !s.lessThan(Scalar(limbs: Scalar.order)) {
            return Scalar(limbs: Scalar.rawSub(sum, Scalar.order))
        }
        return s
    }

    func negated() -> Scalar {
        if isZero { return self }
        return Scalar(limbs: Scalar.rawSub(Scalar.order, limbs))
    }
}

enum Hex {
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return [] }
            out.append(byte)
            index = next
        }
        return out
    }
    static func string(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: self.bigEndian) { Array($0) } }
}

/// Bech32m (BIP350) — enough to read and write silent payment addresses.
enum Bech32m {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let constant: UInt32 = 0x2bc8_30a3

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let gen: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(v)
            for i in 0..<5 where (top >> UInt32(i)) & 1 == 1 { chk ^= gen[i] }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        let bytes = Array(hrp.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 31 }
    }

    static func decode(_ s: String) -> (hrp: String, data: [UInt8])? {
        let lower = s.lowercased()
        guard lower == s || s.uppercased() == s, let sep = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[lower.startIndex..<sep])
        let dataPart = lower[lower.index(after: sep)...]
        guard !hrp.isEmpty, dataPart.count >= 6 else { return nil }
        var data: [UInt8] = []
        for ch in dataPart {
            guard let idx = charset.firstIndex(of: ch) else { return nil }
            data.append(UInt8(idx))
        }
        guard polymod(hrpExpand(hrp) + data) == constant else { return nil }
        return (hrp, Array(data.dropLast(6)))
    }

    static func encode(hrp: String, data: [UInt8]) -> String {
        let values = hrpExpand(hrp) + data
        let mod = polymod(values + [0, 0, 0, 0, 0, 0]) ^ constant
        let checksum = (0..<6).map { UInt8((mod >> (5 * (5 - UInt32($0)))) & 31) }
        return hrp + "1" + String((data + checksum).map { charset[Int($0)] })
    }

    static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0, bits = 0
        var out: [UInt8] = []
        let maxv = (1 << to) - 1
        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                out.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 { out.append(UInt8((acc << (to - bits)) & maxv)) }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return out
    }
}
