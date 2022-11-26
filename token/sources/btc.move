// Copyright (c) Turbos Finance, Inc.
// SPDX-License-Identifier: MIT

/// Coin<BTC> is the mock token used to test in Turbos.
/// It has 9 decimals
module turbos_token::btc {
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::coin::{Self};

    struct BTC has drop {}

    fun init(witness: BTC, ctx: &mut TxContext) {
        transfer::transfer(
            coin::create_currency(witness, 9, ctx),
            tx_context::sender(ctx)
        )
    }
}
