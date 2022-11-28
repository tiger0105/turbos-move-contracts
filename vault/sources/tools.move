// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::tools {
    use std::vector;
    use std::hash;
    use std::bcs;
    use std::string::{Self, String};
    use sui::math;

    
    public fun get_position_key(sender: address, vault: address, pool: address, is_long: bool): String {
        let address_str = address_to_hexstring(&sender);
        let vault_str = address_to_hexstring(&vault);
        let pool_str = address_to_hexstring(&pool);
        let is_long_str = if(is_long) u64_to_hexstring(1) else u64_to_hexstring(0);
        string::append(&mut address_str, vault_str);
        string::append(&mut address_str, pool_str);
        string::append(&mut address_str, is_long_str);

        let hash = hash::sha2_256(*string::bytes(&address_str));
        bytes_to_hexstring(&hash)
    }

    public fun address_to_hexstring(addr: &address): String {
        let bytes = bcs::to_bytes(addr);
        let char_mappping = &b"0123456789abcdef";

        let result_bytes = &mut b"0x";
        let index = 0;
        let still_zero = true;

        while (index < vector::length(&bytes)) {
            let byte = *vector::borrow(&bytes, index);
            index = index + 1;

            if (byte != 0) still_zero = false;
            if (still_zero) continue;

            vector::push_back(result_bytes, *vector::borrow(char_mappping, ((byte / 16) as u64)));
            vector::push_back(result_bytes, *vector::borrow(char_mappping, ((byte % 16) as u64)));
        };

        string::utf8(*result_bytes)
    }

    public fun u64_to_hexstring(num: u64): String {
        let a1 = num / 16;
        let a2 = num % 16;
        let alpha = &b"0123456789abcdef";
        let r = &mut b"";
        vector::push_back(r, *vector::borrow(alpha, a1));
        vector::push_back(r, *vector::borrow(alpha, a2));

        string::utf8(*r)
    }

    public fun bytes_to_hexstring(bytes: &vector<u8>): String {
        let r = &mut string::utf8(b"");

        let index = 0;
        while (index < vector::length(bytes)) {
            let byte = vector::borrow(bytes, index);
            string::append(r, u64_to_hexstring((*byte as u64)));

            index = index + 1;
        };

        *r
    }

    public fun u64_to_string(number: u64): String {
        let places = 20;
        let base = math::pow(10, 19);
        let i = places;

        let str = &mut string::utf8(vector[]);

        while (i > 0) {
            let quotient = number / base;
            if (quotient != 0) {
                number = number - quotient * base
            };

            if (!string::is_empty(str) || quotient != 0) {
                string::append_utf8(str, vector<u8>[((quotient + 0x30) as u8)])
            };

            base = base / 10;
            i = i - 1;
        };

        *str
    }

   #[test]
    public fun test_u64_to_string() {
        assert!(
            u64_to_string(12345) == string::utf8(b"123456"),
            1
        );
        assert!(
            u64_to_string(18446744073709551615) == string::utf8(b"18446744073709551615"),
            2
        );
        assert!(
            u64_to_string(124563165615123165) == string::utf8(b"124563165615123165"),
            3
        );
    }

    #[test]
    public fun test_address_to_hexstring() {
        assert!(address_to_hexstring(&@0xabcdef) == string::utf8(b"0xabcdef"), 1);
    }

    #[test]
    fun test_u64_to_hexstring() {
        assert!(u64_to_hexstring(72) == string::utf8(b"48"), 1);
        assert!(u64_to_hexstring(108) == string::utf8(b"6c"), 1);
    }

    // #[test]
    // fun test_hash() {
    //     let sender = @0xabcdef;
    //     let vault_address = @0xabc;
    //     let pool_address = @0xabcds;
    //     let position_key = get_position_key(sender, pool_address, vault_address, true);

    //     assert!(position_key == string::utf8(b"84b2b7e077e62d929eb620ea8e9dbc74c2ee1dd7708199b4aafb34551438121a"), 1);
    // }
   
}