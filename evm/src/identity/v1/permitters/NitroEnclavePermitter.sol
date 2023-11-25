// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/console2.sol";

import {Sapphire} from "@oasisprotocol/sapphire-contracts/contracts/Sapphire.sol";

contract NitroEnclaveAttestationVerifier {
    error CAExpired();
    error InvalidCoseSignature();

    // CN: aws.nitro-enclaves
    bytes constant ROOT_CA_KEY =
        hex"04fc0254eba608c1f36870e29ada90be46383292736e894bfff672d989444b5051e534a4b1f6dbe3c0bc581a32b7b176070ede12d69a3fea211b66e752cf7dd1dd095f6f1370f4170843d9dc100121e4cf63012809664487c9796284304dc53ff4";
    uint256 constant ROOT_CA_EXPIRY = 2519044085;

    function verifyAttestationDocument(bytes calldata doc) external {
        if (block.timestamp >= ROOT_CA_EXPIRY) revert CAExpired();

        // Array(4) - 84
        // Bytes(4) - 44 // 4 bytes of cbor-encoded protected header
        // Map(1) - a1 // protected header
        // Key: Unsigned(1) - 01
        // Value: Signed(-35) - 3822 // P-384
        // Map(0) - a0 // unprotected header
        // Bytes(long) - 59 // payload
        require(bytes8(doc[0:8]) == bytes8(0x84_44_a1_01_3822_a0_59), "invalid doc");
        uint256 payloadSize = uint16(bytes2(doc[8:10]));
        uint256 payloadStart = 10;
        uint256 payloadEnd = payloadStart + payloadSize;
        bytes calldata payload = doc[payloadStart:payloadEnd];

        // Bytes(short) - 58
        // Unsigned(96) - 60
        require(bytes2(doc[payloadEnd:payloadEnd + 2]) == bytes2(0x58_60));
        uint256 sigStart = payloadEnd + 2;

        verifyCoseSignature({payload: payload, pk: verifyPayload(payload), sig: doc[sigStart:sigStart + 0x60]});
    }

    function verifyPayload(bytes calldata payload) internal returns (bytes calldata pk) {
        // https://docs.aws.amazon.com/enclaves/latest/user/verify-root.html#doc-spec
        // The key order seems to reliably be module_id, digest, timestamp, pcrs, certificate, cabundle, public_key, user_data, nonce.

        uint256 cursor;

        // Map(9) - a9
        // Key: Text(9) - 69
        // Value: Text(9) "module_id" - 69_6D6F64756C655F6964
        // Text(var) - 78
        require(bytes12(payload[cursor:cursor += 12]) == bytes12(0xa9_69_6d6f64756c655f6964_78), "expected module_id");
        uint256 moduleIdLen = uint256(uint8(payload[cursor]));
        cursor += 1 + moduleIdLen;

        // Key: Text(6) "digest" - 66_646967657374
        // Value: Text(6) "SHA384" - 66_534841333834
        // Key: Text(9) "timestamp" - 69_74696D657374616D70
        // Unsigned - 1b
        require(
            bytes25(payload[cursor:cursor += 25]) == bytes25(0x66_646967657374_66_534841333834_69_74696d657374616d70_1b),
            "expected digest & timestamp"
        );
        verifyTimestamp(uint64(bytes8(payload[cursor:cursor += 8])));

        cursor += _verifyPCRs(payload[cursor:]);

        (bytes calldata enclavePublicKey, uint256 certsLen) = _verifyCerts(payload[cursor:]);
        cursor += certsLen;

        cursor += _verifyUserData(payload[cursor:]);

        require(cursor == payload.length, "unparsed payload");

        return enclavePublicKey;
    }

    function _verifyCerts(bytes calldata input) internal returns (bytes calldata publicKey, uint256 adv) {
        uint256 cursor;

        // Key: Text(11) "certificate" - 6b_6365727469666963617465
        // Value: Bytes(long) - 59
        require(bytes13(input[cursor:cursor += 13]) == bytes13(0x6b_6365727469666963617465_59), "expected certificate");
        uint256 certLen = uint16(bytes2(input[cursor:cursor += 2]));
        cursor += certLen; // TODO: return the cert's public key

        // Key: Text(8) "cabundle" - 68_636162756e646c65
        // Value: Array(n) - 80
        require(
            bytes10(input[cursor:cursor += 10]) & 0xfffffffffffffffffff0 == bytes10(0x68_636162756e646c65_80),
            "expected cabundle"
        );
        uint256 cabundleLen = uint256(uint8(input[cursor - 1]) & 0xf);
        bytes calldata pk = input[0:0];

        bytes32 issuerHash = keccak256("aws.nitro-enclaves");

        for (uint256 i; i < cabundleLen; i++) {
            // Bytes(long) - 59
            // require(bytes1(input[cursor:cursor += 1]) == 0x59, "invalid cabundle");
            cursor += 1; // skip the bytes marker to save some gas
            uint256 len = uint256(uint16(bytes2(input[cursor:cursor += 2])));

            if (i == 0) {
                // Skip the zeroth (root) cert, which is loaded from storage.
                cursor += len;
                continue;
            }

            (X509.TbsMeta memory tbs, bytes calldata tbspk) = X509.parse(input[cursor:cursor += len]);
            require(tbs.issuerHash == issuerHash, "mismatched issuer");
            issuerHash = tbs.subjectHash;
            pk = tbspk;
            // TODO: verify issuer signature
        }

        // TODO: verify end entity cert

        return (pk, cursor);
    }

    function _verifyPCRs(bytes calldata input) internal view returns (uint256 adv) {
        // Note: PCR length depends on the digest, but SHA384 is currently the default.
        // Key: Text(4) "pcrs" - 64_70637273
        // Value: Map(16) - b0
        // Key: Unsigned(0) - 00
        // Value: Bytes(short) - 58_30
        require(bytes9(input[0:9]) == bytes9(0x64_70637273_b0_00_58_30), "expected pcrs");
        input = input[9:];
        verifyPCRs(
            input[0 * (48 + 3):0 * (48 + 3) + 48],
            input[1 * (48 + 3):1 * (48 + 3) + 48],
            input[2 * (48 + 3):2 * (48 + 3) + 48],
            input[3 * (48 + 3):3 * (48 + 3) + 48],
            input[4 * (48 + 3):4 * (48 + 3) + 48],
            input[8 * (48 + 3):8 * (48 + 3) + 48]
        );
        return 15 * (48 + 3) + 48 + 9;
    }

    function verifyCoseSignature(bytes calldata payload, bytes calldata pk, bytes calldata sig) internal view {
        bytes memory coseSign1 = bytes.concat(
            // COSE Sign1 structure:
            // Array(4) - 84
            // Text(10) "Signature1" - 6a_5369676E617475726531
            // the protected header from before - 44_A1013822
            // Bytes(0) - 40
            // Bytes(long) - 59
            bytes19(0x84_6a_5369676E617475726531_44_A1013822_40_59),
            bytes2(uint16(payload.length)),
            payload
        );
        // if(!Sapphire.verifyP384Prehashed(pk, Sapphire.sha384(coseSign1), sig)) revert InvalidCoseSignature();
    }

    function _verifyUserData(bytes calldata input) internal view returns (uint256 adv) {
        uint256 cursor;

        // Key: Text(10) "public_key" - 6a_7075626c69635f6b6579
        require(bytes11(input[cursor:cursor += 11]) == bytes11(0x6a_7075626c69635f6b6579), "expected public_key");
        (bytes calldata publicKey, uint256 pkConsumed) = _consumeOptionalBytes(input[cursor:]);
        cursor += pkConsumed;

        // Key: Text(9) "user_data" - 69_757365725f64617461
        require(bytes10(input[cursor:cursor += 10]) == bytes10(0x69_757365725f64617461), "expected user_data");
        (bytes calldata userdata, uint256 userdataConsumed) = _consumeOptionalBytes(input[cursor:]);
        cursor += userdataConsumed;

        // Key: Text(5) "nonce" - 65_6e6f6e6365
        require(bytes6(input[cursor:cursor += 6]) == bytes6(0x65_6e6f6e6365), "expected nonce");
        (bytes calldata nonce, uint256 nonceConsumed) = _consumeOptionalBytes(input[cursor:]);
        cursor += nonceConsumed;

        handleUserData(publicKey, userdata, nonce);

        return cursor;
    }

    function _consumeOptionalBytes(bytes calldata input) internal pure returns (bytes calldata data, uint256 adv) {
        if (input[0] == 0xf6) return (input[0:0], 1);

        require(input[0] == 0x59, "expected pk/ud/nonce bytes");
        uint256 len = uint256(uint16(bytes2(input[1:3])));
        return (input[3:3 + len], len + 3);
    }

    /// @param timestamp The timestamp at which the attestation doc was generated.
    function verifyTimestamp(uint64 timestamp) internal view virtual {}

    /**
     * @param pcr0 A contiguous measure of the contents of the image file, without the section data.
     * @param pcr1 A contiguous measurement of the kernel and boot ramfs data.
     * @param pcr2 A contiguous, in-order measurement of the user applications, without the boot ramfs.
     * @param pcr3 A contiguous measurement of the IAM role assigned to the parent instance. Ensures that the attestation process succeeds only when the parent instance has the correct IAM role.
     * @param pcr4 A contiguous measurement of the ID of the parent instance. Ensures that the attestation process succeeds only when the parent instance has a specific instance ID.
     * @param pcr8 A measure of the signing certificate specified for the enclave image file. Ensures that the attestation process succeeds only when the enclave was booted from an enclave image file signed by a specific certificate.
     */
    function verifyPCRs(
        bytes calldata pcr0,
        bytes calldata pcr1,
        bytes calldata pcr2,
        bytes calldata pcr3,
        bytes calldata pcr4,
        bytes calldata pcr8
    ) internal view virtual {}

    /**
     * @param publicKey An optional DER-encoded key the attestation consumer can use to encrypt data with
     * @param userdata Additional signed user data, defined by protocol
     * @param nonce An optional cryptographic nonce provided by the attestation consumer as a proof of authenticity
     */
    function handleUserData(bytes calldata publicKey, bytes calldata userdata, bytes calldata nonce)
        internal
        view
        virtual
    {}
}

library X509 {
    error CertExpired();
    error CertNotActive();

    struct Cert {
        TbsMeta tbs;
        bytes signature;
    }

    struct TbsMeta {
        bytes32 serial;
        bytes32 issuerHash;
        bytes32 subjectHash;
    }

    function parse(bytes calldata cert) internal view returns (TbsMeta memory, bytes calldata) {
        uint256 cursor = 4; // skip the initial sequence and length

        // SEQUENCE(var(2)) - 30_8_2
        require(bytes2(cert[cursor:cursor += 2]) == bytes2(0x30_8_2), "not tbs");
        uint256 tbsLen = uint16(bytes2(cert[cursor:cursor += 2]));
        (TbsMeta memory meta, bytes calldata pk) = parseTbs(cert[cursor:cursor += tbsLen]);

        // SEQUENCE(10) - 30_0a
        // OID(8) - 06_08
        // ecdsaWithSHA384 - 2a8648ce3d040303
        // require(bytes12(tbs[cursor:cursor += 12]) == bytes12(0x30_0a_06_08_2A8648CE3D040303), "wrong sig");
        cursor += 12; // skip checking the public key format, as only P-384 is supported

        return (meta, cert[0:0]);
    }

    function parseTbs(bytes calldata tbs) internal view returns (TbsMeta memory meta, bytes calldata pk) {
        uint256 cursor = 0;

        // version_element(3) - a0_03
        // integer(1) - 02_02
        // version 2 - 02
        require(bytes5(tbs[cursor:cursor += 5]) == bytes5(0xa0_03_02_01_02), "not v2 tbs");

        // INTEGER - 02
        // require(bytes1(tbs[cursor:cursor += 1]) == bytes1(0x02), "not serial");
        cursor += 1; // ignore integer tag
        uint256 serialLen = uint256(uint8(bytes1(tbs[cursor:cursor += 1])));
        bytes32 serial = keccak256(tbs[cursor:cursor += serialLen]);

        // require(bytes12(tbs[cursor:cursor += 12]) == bytes12(0x30_0a_06_08_2A8648CE3D040303), "wrong sig");
        cursor += 12; // skip checking the public key format, as only P-384 is supported

        (bytes calldata issuer, uint256 issuerSeqLen) = getVarLenSeq(tbs[cursor:]);
        cursor += issuerSeqLen;
        bytes32 issuerHash = keccak256(extractCN(issuer));

        cursor += 1; // skip validity's sequence tag (0x30)
        uint256 validityLen = uint8(bytes1(tbs[cursor:cursor += 1]));
        checkValidity(tbs[cursor:cursor += validityLen]);

        (bytes calldata subject, uint256 subjectSeqLen) = getVarLenSeq(tbs[cursor:]);
        cursor += subjectSeqLen;
        bytes32 subjectHash = keccak256(extractCN(subject));

        meta = TbsMeta({serial: serial, issuerHash: issuerHash, subjectHash: subjectHash});

        cursor += 1; // skip the SPKI sequence tag (0x30)
        uint256 spkiLen = uint256(uint8(bytes1(tbs[cursor:cursor += 1])));
        cursor += spkiLen;
        pk = tbs[cursor - 97:cursor];

        // TODO: consider verifying basicConstraints
    }

    /// Extracts a sequence that may have 0, 1, or 2 additional length bytes.
    function getVarLenSeq(bytes calldata input) internal view returns (bytes calldata, uint256 adv) {
        uint256 cursor;
        require(bytes1(input[cursor:cursor += 1]) == bytes1(0x30), "not seq");
        uint256 len = uint256(uint8(bytes1(input[cursor:cursor += 1])));
        if (len == 0x81) {
            len = uint256(uint8(bytes1(input[cursor:cursor += 1])));
        } else if (len == 0x82) {
            len = uint256(uint16(bytes2(input[cursor:cursor += 2])));
        } else {
            require((len & 0x80) != 0x80, "seq too big");
        }
        return (input[cursor:cursor += len], cursor);
    }

    function extractCN(bytes calldata input) internal pure returns (bytes calldata) {
        uint256 cursor;
        while (cursor != input.length) {
            // require(bytes1(input[cursor:cursor += 1]) == bytes1(0x31), "not rdn");
            cursor += 1; // skip tag byte (0x31)
            uint256 rdnLen = uint256(uint8(bytes1(input[cursor:cursor += 1])));
            // SEQUENCE(n)- 30_xx
            // OID(commnName) - _06_03_550403
            if (bytes7(input[cursor:cursor + 7]) & 0xff00ffffffffff != bytes7(0x30_00_0603550403)) {
                cursor += rdnLen;
                continue;
            }
            cursor += 8;
            uint256 cnLen = uint256(uint8(bytes1(input[cursor:cursor += 1])));
            return input[cursor:cursor + cnLen];
        }
        revert("no CN");
    }

    function checkValidity(bytes calldata validity) internal view {
        uint256 nbf = parseISO8609(bytes13(validity[2:15]));
        uint256 exp = parseISO8609(bytes13(validity[17:30]));
        uint256 fuzz = (exp - nbf) * 3_000 / 10_000; // allow 30% on either side
        if (block.timestamp > exp + fuzz) revert CertExpired();
        if (block.timestamp < nbf - fuzz) revert CertNotActive();
    }

    /// Parses an ISO-8601 timestamp (YYMMddHHmmssZ) into an approximate unix timestamp.
    function parseISO8609(bytes13 isodate) internal pure returns (uint256) {
        require(isodate[12] == 0x5a, "not utc tz");
        bytes32 isonums = bytes32(uint256(bytes32(isodate)) - (0x303030303030303030303030 << 160));
        uint256 year = uint8(isonums[0]) * 10 + uint256(uint8(isonums[1]));
        uint256 month = uint8(isonums[2]) * 10 + uint256(uint8(isonums[3]));
        uint256 day = uint8(isonums[4]) * 10 + uint256(uint8(isonums[5]));
        uint256 hour = uint8(isonums[6]) * 10 + uint256(uint8(isonums[7]));
        uint256 minute = uint8(isonums[8]) * 10 + uint256(uint8(isonums[9]));
        uint256 second = uint8(isonums[10]) * 10 + uint8(isonums[11]);
        return (
            second + (1 minutes * minute) + (1 hours * hour) + (1 days * (day - 1 + cumulativeDays(month, year)))
                + (365.2425 days * year + 946702800)
        );
    }

    function cumulativeDays(uint256 month, uint256 year) internal pure returns (uint256) {
        if (month == 1) return 0;
        uint256 leap = (year & 3) == 0 && (year % 100 != 0 || year % 400 == 0) ? 1 : 0;
        if (month == 2) return 31;
        if (month == 3) return 59 + leap;
        if (month == 4) return 90 + leap;
        if (month == 5) return 120 + leap;
        if (month == 6) return 151 + leap;
        if (month == 7) return 181 + leap;
        if (month == 8) return 212 + leap;
        if (month == 9) return 243 + leap;
        if (month == 10) return 273 + leap;
        if (month == 11) return 304 + leap;
        if (month == 12) return 334 + leap;
        revert("bad month");
    }
}