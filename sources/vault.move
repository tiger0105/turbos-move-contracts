// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

module turbos::vault {
    use sui::transfer;
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};

    struct Position has key, store {
        id: UID,
        collateral: u64,
        size: u64
    }

    public fun owner(counter: &Counter): address {
        counter.owner
    }

    public fun value(counter: &Counter): u64 {
        counter.value
    }

    public entry fun initialize(ctx: &mut TxContext) {
        /// initialize
    }

    public entry fun swap(ctx: &mut TxContext) {
    }
}